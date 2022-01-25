# frozen_string_literal: true

require "monitor"

module MiniRacer

  class Context
    def heap_stats
      {
        total_physical_size: 0,
        total_heap_size_executable: 0,
        total_heap_size: 0,
        used_heap_size: 0,
        heap_size_limit: 0,
      }
    end

    def stop
      if @context.respond_to?(:stop)
        if @entered
          @context.stop
          @stopped = true
          stop_attached
        end
      end
    end

    private

    @@context_initialized = false
    @@use_strict = false

    def init_unsafe(isolate, snapshot)
      unless defined?(Polyglot::InnerContext)
        raise "TruffleRuby #{RUBY_ENGINE_VERSION} does not have support for inner contexts, use a more recent version"
      end

      unless Polyglot.languages.include? "js"
        raise "The language 'js' is not available, you likely need to `export TRUFFLERUBYOPT='--jvm --polyglot'`" +
                "Note that you need TruffleRuby+GraalVM and not just the TruffleRuby standalone to use #{self.class}"
      end

      @context = Polyglot::InnerContext.new
      @@context_initialized = true
      @js_object = @context.eval('js', 'Object')
      @isolate_mutex = Monitor.new
      @stopped = false
      @entered = false
      @has_entered = false
      if isolate && snapshot
        isolate.instance_variable_set(:@snapshot, snapshot)
      end
      if snapshot
        @snapshot = snapshot
      elsif isolate
        @snapshot = isolate.instance_variable_get(:@snapshot)
      else
        @snapshot = nil
      end
    end

    def dispose_unsafe
      @context.close
    end

    def eval_unsafe(str, filename)
      @entered = true
      eval_in_context('"use strict;"') if !@has_entered && @@use_strict
      if !@has_entered && @snapshot
        snapshot_src = encode(@snapshot.instance_variable_get(:@source))
        begin
          eval_in_context(snapshot_src)
        rescue RuntimeError => e
          if e.message == "Polyglot::InnerContext was terminated forcefully"
            raise ScriptTerminatedError, "JavaScript was terminated (either by timeout or explicitly)"
          else
            raise e
          end
        end
      end
      @has_entered = true
      raise RuntimeError, "TruffleRuby does not support eval after stop" if @stopped
      raise ArgumentError, "wrong type argument #{str.class} (should be a string)" unless str.kind_of?(String)
      raise ArgumentError, "wrong type argument #{filename.class} (should be a string)" unless filename.nil? || filename.kind_of?(String)

      str = encode(str)
      begin
        translate do
          eval_in_context(str)
        end
      rescue RuntimeError => e
        if e.message == "Polyglot::InnerContext was terminated forcefully"
          raise ScriptTerminatedError, "JavaScript was terminated (either by timeout or explicitly)"
        else
          raise e
        end
      rescue SystemStackError => e
        raise RuntimeError, e.message
      end
    ensure
      @entered = false
    end

    def call_unsafe(function_name, *arguments)
      @entered = true
      if !@has_entered && @snapshot
        eval_in_context("use strict;") if @@use_strict
        src = encode(@snapshot.instance_variable_get(:source))
        begin
          eval_in_context(src)
        rescue RuntimeError => e
          raise e unless e.message == "Polyglot::InnerContext was terminated forcefully"
        end
      end
      @has_entered = true
      raise RuntimeError, "TruffleRuby does not support call after stop" if @stopped
      begin
        translate do
          function = eval_in_context(function_name)
          function.call(*convert_ruby_to_js(arguments))
        end
      rescue RuntimeError => e
        raise e unless e.message == "Polyglot::InnerContext was terminated forcefully"
      rescue SystemStackError => e
        raise RuntimeError, e.message
      end
    ensure
      @entered = false
    end

    def create_isolate_value
      # Returning a dummy object since TruffleRuby does not have a 1-1 concept with isolate.
      # However, code and ASTs are shared between contexts.
      Isolate.new
    end

    def isolate_mutex
      @isolate_mutex
    end

    class ExternalFunction
      private

      def notify_v8
        name = @name.encode(::Encoding::UTF_8)
        wrapped = lambda do |*args|
          converted = @parent.send(:convert_js_to_ruby, args)
          @parent.send(:convert_ruby_to_js, @callback.call(*converted))
        end

        if @parent_object.nil?
          # set global name to proc
          result = @parent.eval_in_context('this')
          result[name] = wrapped
        else
          parent_object_eval = @parent_object_eval.encode(::Encoding::UTF_8)
          result = @parent.eval_in_context(parent_object_eval)
          result[name] = wrapped
          # set evaluated object results name to proc
        end
      end
    end

    def translate
      convert_js_to_ruby yield
    rescue ::RuntimeError => e
      if e.message.start_with?('SyntaxError:')
        error_class = MiniRacer::ParseError
      else
        error_class = MiniRacer::RuntimeError
      end

      backtrace = e.backtrace.map { |line| line.sub('(eval)', '(mini_racer)') }
      raise error_class, e.message, backtrace
    end

    def convert_js_to_ruby(value)
      case value
      when true, false, Integer, Float
        value
      else
        if value.nil?
          nil
        elsif value.respond_to?(:call)
          MiniRacer::JavaScriptFunction.new
        elsif value.respond_to?(:to_str)
          value.to_str
        elsif value.respond_to?(:to_ary)
          value.to_ary.map do |e|
            if e.respond_to?(:call)
              nil
            else
              convert_js_to_ruby(e)
            end
          end
        elsif is_time(value)
          js_date_to_time(value)
        elsif is_symbol(value)
          js_symbol_to_symbol(value)
        else
          object = value
          h = {}
          object.instance_variables.each do |member|
            v = object[member]
            unless v.respond_to?(:call)
              h[member.to_s] = convert_js_to_ruby(v)
            end
          end
          h
        end
      end
    end

    def is_time(value)
      f = eval_in_context("(x) => { return x instanceof Date };")
      f.call(value)
    end

    def js_date_to_time(value)
      f = eval_in_context("(x) => { return x.getTime(x) };")
      millis = f.call(value)
      Time.at(Rational(millis, 1000))
    end

    def is_symbol(value)
      f = eval_in_context("(x) => { return typeof x === 'symbol' };")
      f.call(value)
    end

    def js_symbol_to_symbol(value)
      f = eval_in_context("(x) => { var r = x.description; return r === undefined ? 'undefined' : r };")
      f.call(value).to_sym
    end

    def convert_ruby_to_js(value)
      case value
      when nil, true, false, Integer, Float, String
        value
      when Array
        value.map { |e| convert_ruby_to_js(e) }
      when Hash
        h = @js_object.new
        value.each_pair do |k, v|
          h[convert_ruby_to_js(k)] = convert_ruby_to_js(v)
        end
        h
      when Symbol
        value.to_s
      when Time
        eval_in_context("new Date(#{value.to_f * 1000})")
      when DateTime
        eval_in_context("new Date(#{value.to_time.to_f * 1000})")
      else
        "Undefined Conversion"
      end
    end

    def encode(string)
      raise ArgumentError unless string
      string.encode(::Encoding::UTF_8)
    end

    class_eval <<-'RUBY', "(mini_racer)", 1
        def eval_in_context(code); @context.eval('js', code); end
    RUBY

  end

  class Isolate
    def init_with_snapshot(snapshot)
      # TruffleRuby does not have a 1-1 concept with isolate.
      # However, isolate can hold a napshot, and code and ASTs are shared between contexts.
      @snapshot = snapshot
    end

    def low_memory_notification
      GC.start
    end

    def idle_notification(idle_time)
      true
    end
  end

  class Platform
    def self.set_flag_as_str!(flag)
      raise ArgumentError, "wrong type argument #{flag.class} (should be a string)" unless flag.kind_of?(String)
      raise MiniRacer::PlatformAlreadyInitialized, "The platform is already initialized." if Context.class_variable_get(:@@context_initialized)
      Context.class_variable_set(:@@use_strict, true) if "--use_strict" == flag
    end
  end

  class Snapshot
    def load(str)
      raise ArgumentError, "wrong type argument #{str.class} (should be a string)" unless str.kind_of?(String)
      # Intentionally noop since TruffleRuby mocks the snapshot API
    end

    def warmup_unsafe!(src)
      # Intentionally noop since TruffleRuby mocks the snapshot API
      # by replaying snapshot source before the first eval/call
      self
    end
  end
end