# frozen_string_literal: true

require "active_support"
require "active_support/cache"
require "active_support/core_ext/numeric/bytes"
require "active_support/isolated_execution_state"
require "active_support/notifications"

# The railtie is the only part of QueryStash that expects ActiveSupport: it hands the rest what it
# needs from it, as options of `config.query_stash`.
module QueryStash
  class Railtie < Rails::Railtie
    class << self
      # The `adapter` (QueryStash::ActiveRecord or QueryStash::Mongo) for the app's `config`, with
      # the cache store `config.query_stash.cache_store` names.
      def build(adapter, config)
        adapter.new(config, cache_store: build_cache_store(adapter, *Array(config.query_stash.cache_store)))
      end

      # Takes the same values as Rails' `config.cache_store`. `:file_store` gets a QueryStash::FileStore,
      # with the adapter's prefix on the directory's basename so each adapter keeps its own directory:
      # "tmp/stash" becomes "tmp/active-record-stash".
      def build_cache_store(adapter, store, *parameters)
        return ActiveSupport::Cache.lookup_store(store, *parameters) unless store == :file_store

        require_relative "file_store"

        cache_path, options = parameters

        QueryStash::FileStore.new(
          File.join(File.dirname(cache_path), "#{adapter.prefix}-#{File.basename(cache_path)}"),
          **options.to_h
        )
      end
    end

    config.before_configuration do
      config.query_stash = ActiveSupport::OrderedOptions.new.update(
        enabled: true,
        isolated_state: ActiveSupport::IsolatedExecutionState,
        instrumenter: ActiveSupport::Notifications,
        error_reporter: ActiveSupport.error_reporter,
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

        QueryStash::ActiveRecord.set(app, QueryStash::Railtie.build(QueryStash::ActiveRecord, app.config))
        app.config.middleware.use QueryStash::ActiveRecord::Middleware, app
      end

      if defined?(::Rails::Mongoid::Railtie)
        require_relative "mongo"

        QueryStash::Mongo.set(app, QueryStash::Railtie.build(QueryStash::Mongo, app.config))
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

        if ::ActiveRecord::ConnectionAdapters.const_defined?(:QueryIntent)
          ::ActiveRecord::ConnectionAdapters::QueryIntent.prepend(QueryStash::ActiveRecord::IntentPatch)
        end

        %i[
          active_record_sqlite3adapter
          active_record_postgresqladapter
          active_record_mysql2adapter
          active_record_trilogyadapter
        ].each do |hook|
          ActiveSupport.on_load(hook) do
            # Rails 8.2 runs queries as intents, earlier versions through `internal_exec_query`.
            patch = method_defined?(:execute_intent) ? :IntentAdapterPatch : :AdapterPatch
            prepend QueryStash::ActiveRecord.const_get(patch)
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
