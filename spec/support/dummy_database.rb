# frozen_string_literal: true

module DummyDatabase
  extend self

  def prepare
    create_unless_exists
    ActiveRecord::Schema.verbose = false
    load Rails.root.join("db/schema.rb").to_s
  end

  private

  def create_unless_exists
    ActiveRecord::Base.connection.verify!
  rescue ActiveRecord::NoDatabaseError
    ActiveRecord::Tasks::DatabaseTasks.create(ActiveRecord::Base.connection_db_config)
  end
end
