# frozen_string_literal: true

require "active_support/core_ext/numeric/bytes"

module QueryStash
  class Railtie < Rails::Railtie
    config.before_configuration do
      config.query_stash = ActiveSupport::OrderedOptions.new.update(
        enabled: true,
        cache_store: [:memory_store, { size: 128.megabytes, compress: true }],
        raise_on_cache_error: Rails.env.development? || Rails.env.test?
      )
    end

    # Builds the stores at boot, so a bad `cache_store` fails here and not on the first query.
    config.after_initialize do
      QueryStash::ActiveRecord.cache if defined?(QueryStash::ActiveRecord)
      QueryStash::Mongo.cache if defined?(QueryStash::Mongo)
    end

    # The middleware stack is built before ActiveRecord::Base and Mongoid::Document load, so the
    # middlewares can't be added from their on_load hooks: they go in whenever the framework is present.
    initializer "query_stash.middleware" do |app|
      if defined?(::ActiveRecord::Railtie)
        require_relative "active_record"

        app.config.middleware.use QueryStash::ActiveRecord::Middleware
      end

      if defined?(::Rails::Mongoid::Railtie)
        require_relative "mongo"

        app.config.middleware.use QueryStash::Mongo::Middleware
      end
    end

    initializer "query_stash.active_job" do
      ActiveSupport.on_load(:active_job) do
        if defined?(::ActiveRecord::Railtie)
          around_perform { |_job, block| ::ActiveRecord::Base.with_query_stash(&block) }
        end

        around_perform { |_job, block| ::Mongo.with_query_stash(&block) } if defined?(::Rails::Mongoid::Railtie)
      end
    end

    config.to_prepare do |_app|
      ActiveSupport.on_load(:active_record) do
        require_relative "active_record"

        extend QueryStash::ActiveRecord::ContextMethods

        %i[
          active_record_sqlite3adapter
          active_record_postgresqladapter
          active_record_mysql2adapter
          active_record_trilogyadapter
        ].each do |hook|
          ActiveSupport.on_load(hook) do
            prepend QueryStash::ActiveRecord::AdapterPatch
          end
        end
      end

      ActiveSupport.on_load(:mongoid) do
        require_relative "mongo"

        ::Mongo.extend(QueryStash::Mongo::ContextMethods)

        ::Mongo::Collection::View::Iterable.prepend(
          QueryStash::Mongo::AdapterPatch
        )
      end
    end
  end
end
