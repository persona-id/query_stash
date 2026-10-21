# frozen_string_literal: true

require "active_support/core_ext/numeric/bytes"
require "active_support/isolated_execution_state"

module QueryStash
  class Railtie < Rails::Railtie
    config.before_configuration do
      config.query_stash = ActiveSupport::OrderedOptions.new.update(
        enabled: true,
        isolated_state: ActiveSupport::IsolatedExecutionState,
        cache_store: [:memory_store, { size: 128.megabytes, compress: true }],
        raise_on_cache_error: Rails.env.development? || Rails.env.test?
      )
    end

    # Builds each adapter's instance from the app's config, which the environment files have already
    # set by now, and before config/initializers run, so those can configure its rules.
    #
    # The middleware stack is built before ActiveRecord::Base and Mongoid::Document load, so the
    # middlewares can't be added from their on_load hooks: they go in whenever the framework is present.
    initializer "query_stash", before: :load_config_initializers do |app|
      if defined?(::ActiveRecord::Railtie)
        require_relative "active_record"

        QueryStash::ActiveRecord.set(app, QueryStash::ActiveRecord.new(app.config))
        app.config.middleware.use QueryStash::ActiveRecord::Middleware, app
      end

      if defined?(::Rails::Mongoid::Railtie)
        require_relative "mongo"

        QueryStash::Mongo.set(app, QueryStash::Mongo.new(app.config))
        app.config.middleware.use QueryStash::Mongo::Middleware, app
      end
    end

    initializer "query_stash.active_job" do |app|
      ActiveSupport.on_load(:active_job) do
        if defined?(::ActiveRecord::Railtie)
          around_perform { |_job, block| QueryStash::ActiveRecord[app].enable!(&block) }
        end

        around_perform { |_job, block| QueryStash::Mongo[app].enable!(&block) } if defined?(::Rails::Mongoid::Railtie)
      end
    end

    config.to_prepare do |_app|
      ActiveSupport.on_load(:active_record) do
        require_relative "active_record"

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

        ::Mongo::Collection::View::Iterable.prepend(
          QueryStash::Mongo::AdapterPatch
        )
      end
    end
  end
end
