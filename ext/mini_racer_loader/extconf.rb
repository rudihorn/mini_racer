if RUBY_ENGINE == "truffleruby"
  File.write("Makefile", dummy_makefile($srcdir).join(""))
  return
end

require 'mkmf'

extension_name = 'mini_racer_loader'
dir_config extension_name

$CXXFLAGS += " -fvisibility=hidden "

create_makefile extension_name
