# frozen_string_literal: true

$LOAD_PATH.push File.expand_path("lib", __dir__)

Gem::Specification.new do |spec|
  spec.name = "hanikamu-operation"
  spec.version = "0.1.2"
  spec.authors = ["Nicolai Seerup", "Alejandro Jimenez"]

  spec.summary = "Service objects with guards, distributed locks, and transactions"
  spec.description = <<~DESC
    Ruby gem for building robust service operations with guard validations, distributed mutex locks via Redlock,
    database transactions, and comprehensive error handling. Thread-safe and designed for production Rails applications.
  DESC
  spec.homepage = "https://github.com/Hanikamu/hanikamu-operation"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Hanikamu/hanikamu-operation"
  spec.metadata["changelog_uri"] = "https://github.com/Hanikamu/hanikamu-operation/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Dependencies
  spec.add_dependency "activemodel", ">= 6.0", "< 9.0"
  spec.add_dependency "activerecord", ">= 6.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 6.0", "< 9.0"
  spec.add_dependency "hanikamu-service", "~> 0.1"
  spec.add_dependency "redlock", "~> 2.0"
  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
