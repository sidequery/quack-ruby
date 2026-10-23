Gem::Specification.new do |spec|
  spec.name = "quack-ruby"
  spec.version = "0.1.0"
  spec.authors = ["Nico"]
  spec.summary = "Direct Quack protocol client for Ruby, powered by Rust"
  spec.license = "MIT"
  spec.homepage = "https://github.com/sidequery/quack-ruby"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "ext/**/*", "README.md", "LICENSE*"].select do |path|
      File.file?(path) && !path.match?(%r{(?:/target/|\.dSYM(?:/|$)|/Makefile$|/mkmf.log$|\.(?:bundle|so|o)$)})
    end
  end
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/quack/extconf.rb"]
  spec.add_dependency "rb_sys", "~> 0.9"
  spec.add_dependency "bigdecimal", ">= 3.1"
  spec.add_dependency "json", ">= 2.6"
end
