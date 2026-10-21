# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "tmpdir"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]

# The types are written as annotations in lib/, and exported to sig/ for whoever uses the gem. Every file in
# lib/ is exported (--opt-out), so a new one has signatures without anyone remembering to ask for them.
namespace :sig do
  desc "Export the inline annotations in lib/ to sig/"
  task :export do
    rm_rf "sig"
    sh "bundle", "exec", "rbs-inline", "--opt-out", "--output=sig", "lib"
  end

  desc "Fail unless sig/ is what the inline annotations in lib/ export"
  task :verify do
    Dir.mktmpdir do |exported|
      sh "bundle", "exec", "rbs-inline", "--opt-out", "--output=#{exported}", "lib", verbose: false

      next if system("diff", "-ru", "sig", exported)

      abort "sig/ is not what the annotations in lib/ export: run `bundle exec rake sig:export` and commit it."
    end
  end
end

desc "Check the code against the signatures with Steep (needs `bundle exec rbs collection install` once)"
task :steep do
  sh "bundle", "exec", "steep", "check"
end

desc "Check the types: sig/ is up to date, and the code agrees with it"
task types: %w[sig:verify steep]
