# frozen_string_literal: true

require_relative "lib/query_stash/version"

Gem::Specification.new do |spec|
  spec.name = "query_stash"
  spec.version = QueryStash::VERSION
  spec.authors = ["Persona"]
  spec.email = ["rubygems@withpersona.com"]

  spec.summary = "Cross-request, allowlisted query result caching for ActiveRecord and MongoDB."
  spec.description = "Caches the results of allowlisted SELECT queries (and MongoDB finds) across requests, " \
                     "below the ORM, with per-rule TTLs computed from the result."
  spec.homepage = "https://github.com/persona-id/query_stash"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/persona-id/query_stash"
  spec.metadata["changelog_uri"] = "https://github.com/persona-id/query_stash/blob/main/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile gemfiles/ .gitignore .rspec .rubocop.yml .tool-versions spec/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.2"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
