# frozen_string_literal: true

require "rails"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "mongoid"
require "sequel-rails"

# DATABASE_URL is ActiveRecord's, which spells SQLite `sqlite3`: sequel-rails connects with it too.
require "sequel/adapters/sqlite"
Sequel::SQLite::Database.send(:set_adapter_scheme, :sqlite3)

require "query_stash"

# The engine under test comes from DATABASE_URL, e.g.:
#
#   sqlite3::memory:                                (default)
#   postgres://postgres:postgres@127.0.0.1:5432/query_stash_test
#   trilogy://root:mysql@127.0.0.1:3306/query_stash_test
#   mongodb://127.0.0.1:27017/query_stash_test
#
# A MongoDB URL goes to Mongoid, and ActiveRecord falls back to an in-memory SQLite database so the
# ActiveRecord side still boots.
ENV["MONGODB_URL"] = ENV.delete("DATABASE_URL") if ENV["DATABASE_URL"]&.start_with?("mongodb")
ENV["DATABASE_URL"] ||= "sqlite3::memory:"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    # As in production, so the models load ActiveRecord and Mongoid, and the stash hooks run, at boot.
    config.eager_load = true
    config.logger = Logger.new(nil)
    config.secret_key_base = "query-stash-dummy"
  end

  def self.database
    ENV["MONGODB_URL"] ? :mongo : :active_record
  end
end
