require "rake/testtask"
require "fileutils"

ROOT = __dir__
desc "Build the native extension"
task :compile do
  Dir.chdir(File.join(ROOT, "ext/quack")) do
    ruby "extconf.rb"
    sh "make"
    FileUtils.cp("quack_native.#{RbConfig::CONFIG.fetch('DLEXT')}", "../../lib/quack/")
  end
end
Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/**/*_test.rb"
end
task default: [:compile, :test]
desc "Build the source gem"
task :package do
  FileUtils.mkdir_p("pkg")
  sh "gem", "build", "quack.gemspec", "--output", "pkg/quack-0.1.0.gem"
end
