# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |file| require file }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Examples tagged `database: :active_record` or `database: :mongo` run real queries, so they only
  # run against the engine DATABASE_URL points at.
  config.filter_run_excluding database: ->(database) { database != Dummy.database }

  config.before(:suite) do
    DummyDatabase.prepare if Dummy.database == :active_record
  end

  config.order = :random
  Kernel.srand config.seed
end
