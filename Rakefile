require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

begin
  require "rb_sys/extensiontask"

  RbSys::ExtensionTask.new("renderhive_native") do |ext|
    ext.lib_dir = "lib/renderhive"
  end

  task test: :compile
  task default: %i[compile test]
rescue LoadError
  task default: :test
end
