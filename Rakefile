require "rake/testtask"
require "rake/extensiontask"
require "rubygems/package_task"

GEMSPEC = Gem::Specification.load("quack-ruby.gemspec")
Gem::PackageTask.new(GEMSPEC).define

Rake::ExtensionTask.new("quack_native", GEMSPEC) do |extension|
  extension.ext_dir = "ext/quack"
  extension.lib_dir = "lib/quack"
  extension.source_pattern = "**/*.{rs,rb,toml,lock}"
  extension.cross_compile = ENV.key?("RUBY_TARGET")
  extension.cross_platform = [ENV["RUBY_TARGET"]].compact
  extension.cross_compiling do |spec|
    spec.files.reject! { |path| path.start_with?("ext/") }
    spec.dependencies.reject! { |dependency| dependency.name == "rb_sys" }
    if ENV.fetch("RUBY_TARGET").end_with?("-linux")
      spec.platform = Gem::Platform.new("#{ENV.fetch('RUBY_TARGET')}-gnu")
      spec.required_rubygems_version = ">= 3.3.22"
    end
  end
end
Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/**/*_test.rb"
end
task default: [:compile, :test]
