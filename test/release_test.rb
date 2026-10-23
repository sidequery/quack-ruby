require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class ReleaseTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CURRENT = Gem::Specification.load(Dir[File.join(ROOT, "*.gemspec")].fetch(0)).version.to_s

  def setup
    @directory = Dir.mktmpdir("quack-release")
    @checkout = File.join(@directory, "checkout")
    @remote = File.join(@directory, "remote.git")
    FileUtils.mkdir_p(@checkout)
    paths = Dir.chdir(ROOT) { Dir["*.gemspec", "Gemfile.lock", "gemfiles/*.lock"] }
    paths.concat(%w[lib/quack.rb ext/quack/Cargo.toml ext/quack/Cargo.lock]) if File.file?(File.join(ROOT, "quack-ruby.gemspec"))
    paths.each do |path|
      target = File.join(@checkout, path)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(ROOT, path), target)
    end
    @dependency_lock = File.join(@checkout, "vendor/bundle/dependency/Gemfile.lock")
    FileUtils.mkdir_p(File.dirname(@dependency_lock))
    File.write(@dependency_lock, "    cached-dependency (9.9.9)\n")
    File.write(File.join(@checkout, ".gitignore"), "/vendor/\n")
    command("git", "init", "--bare", @remote)
    command("git", "init", "-b", "main")
    command("git", "config", "user.name", "Release test")
    command("git", "config", "user.email", "release@example.invalid")
    command("git", "add", ".")
    command("git", "commit", "-m", "Initial")
    command("git", "remote", "add", "origin", @remote)
    command("git", "push", "origin", "main")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def command(*args)
    output, status = Open3.capture2e(*args, chdir: @checkout)
    assert status.success?, output
    output.strip
  end

  def release(bump: "patch", tag: "")
    Open3.capture2e({"BUMP" => bump, "RELEASE_TAG" => tag, "GITHUB_REF" => "refs/heads/main",
                    "GITHUB_OUTPUT" => File.join(@directory, "outputs")},
                   RbConfig.ruby, File.join(ROOT, "script/prepare-release"), chdir: @checkout)
  end

  %w[major minor patch].each_with_index do |bump, index|
    define_method("test_#{bump}_bumps_and_pushes_consistent_versions") do
      parts = CURRENT.split(".").map(&:to_i)
      parts[index] += 1
      ((index + 1)...3).each { |position| parts[position] = 0 }
      version = parts.join(".")
      output, status = release(bump: bump)
      assert status.success?, output
      spec = Gem::Specification.load(Dir[File.join(@checkout, "*.gemspec")].fetch(0))
      assert_equal version, spec.version.to_s
      Dir[File.join(@checkout, "Gemfile.lock"), File.join(@checkout, "gemfiles/*.lock")].each do |lock|
        assert_includes File.read(lock), "    #{spec.name} (#{version})"
      end
      assert_equal "    cached-dependency (9.9.9)\n", File.read(@dependency_lock)
      if spec.name == "quack-ruby"
        assert_includes File.read(File.join(@checkout, "lib/quack.rb")), "VERSION = \"#{version}\""
        assert_includes File.read(File.join(@checkout, "ext/quack/Cargo.toml")), "version = \"#{version}\""
        assert_includes File.read(File.join(@checkout, "ext/quack/Cargo.lock")), "name = \"quack-ruby\"\nversion = \"#{version}\""
      end
      assert_equal command("git", "rev-parse", "HEAD"), command("git", "--git-dir", @remote, "rev-parse", "refs/tags/v#{version}^{commit}")
      assert_empty command("git", "status", "--porcelain")
    end
  end

  def test_existing_tag_keeps_version_and_commit
    command("git", "tag", "v#{CURRENT}")
    before = command("git", "rev-parse", "HEAD")
    output, status = release(tag: "v#{CURRENT}")
    assert status.success?, output
    assert_equal before, command("git", "rev-parse", "HEAD")
    assert_includes File.read(File.join(@directory, "outputs")), "tag=v#{CURRENT}"
  end

  def test_mismatched_tag_is_rejected
    command("git", "tag", "v9999.0.0")
    output, status = release(tag: "v9999.0.0")
    refute status.success?
    assert_includes output, "release tag does not match source version"
    assert_empty command("git", "status", "--porcelain")
  end
end
