# frozen_string_literal: true

# The Sequel connection of the dummy app, which sequel-rails made to the database DATABASE_URL points at, with
# a table of its own. (An in-memory SQLite database is not ActiveRecord's: they are two connections.)
module SequelDatabase
  extend self

  def db
    @db ||= Sequel::Model.db.tap do |db|
      db.loggers << queries
      db.create_table?(:sequel_posts) do
        primary_key :id
        String :status
        String :title
      end
    end
  end

  # The SQL Sequel was sent: it logs each query at `info`.
  def queries
    @queries ||= QueryLog.new
  end

  class QueryLog
    attr_reader :messages

    def initialize
      @messages = []
    end

    def info(message)
      @messages << message
    end

    def debug(*); end
    def warn(*); end
    def error(*); end
  end
end
