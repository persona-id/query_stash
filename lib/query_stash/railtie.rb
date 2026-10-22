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
    # The options an adapter can set for itself, in `config.query_stash.active_record` and
    # `config.query_stash.mongo`. What it does not set, it takes from `config.query_stash`.
    ADAPTER_OPTIONS = %i[enabled isolated_state instrumenter error_reporter cache_store].freeze

    # The adapters' sections of `config.query_stash`, which are not options of their own.
    ADAPTER_SECTIONS = %i[active_record mongo].freeze

    class << self
      # The `adapter` (QueryStash::ActiveRecord or QueryStash::Mongo) for the app's `config`, with
      # its own options over the ones of `config.query_stash`, and the cache store they name.
      #: (singleton(Base) adapter, untyped config) -> Base
      def build(adapter, config)
        options = options_for(adapter, config)

        # `cache_store` takes the same values as Rails' `config.cache_store`.
        adapter.new(
          **options.slice(:enabled, :isolated_state, :instrumenter, :error_reporter, :raise_on_cache_error),
          cache_store: ActiveSupport::Cache.lookup_store(*Array(options.cache_store))
        )
      end

      # `config.query_stash`, with what the adapter's own section sets on top of it. A section only
      # holds what the user set, so an option it has, even a `false` or a `nil`, is the user's choice.
      #: (singleton(Base) adapter, untyped config) -> untyped
      def options_for(adapter, config)
        root = config.query_stash
        own = root[adapter.name.to_s.demodulize.underscore.to_sym] || {}

        ActiveSupport::OrderedOptions.new.update(root.except(*ADAPTER_SECTIONS)).update(own.slice(*ADAPTER_OPTIONS))
      end
    end

    # What follows is Rails' own DSL: it runs blocks with another `self` and reaches methods that are
    # added at runtime, so there is nothing for Steep to check it against.
    # steep:ignore:start
    config.before_configuration do
      config.query_stash = ActiveSupport::OrderedOptions.new.update(
        enabled: true,
        isolated_state: ActiveSupport::IsolatedExecutionState,
        instrumenter: ActiveSupport::Notifications,
        error_reporter: ActiveSupport.error_reporter,
        cache_store: [:memory_store, { size: 128.megabytes, compress: true }],
        raise_on_cache_error: Rails.env.development? || Rails.env.test?
      )

      # Only for the adapters that are loaded.
      config.query_stash.active_record = ActiveSupport::OrderedOptions.new if defined?(::ActiveRecord::Railtie)
      config.query_stash.mongo = ActiveSupport::OrderedOptions.new if defined?(::Rails::Mongoid::Railtie)
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

        # What the stash does for the Rails in use needs ActiveRecord.
        ActiveSupport.on_load(:active_record) do
          QueryStash::ActiveRecord[app].extend(QueryStash::ActiveRecord.implementation::Stash)
        end
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

        implementation = QueryStash::ActiveRecord.implementation
        if implementation.const_defined?(:IntentPatch)
          ::ActiveRecord::ConnectionAdapters::QueryIntent.prepend(implementation::IntentPatch)
        end

        %i[
          active_record_sqlite3adapter
          active_record_postgresqladapter
          active_record_mysql2adapter
          active_record_trilogyadapter
        ].each do |hook|
          ActiveSupport.on_load(hook) do
            patch = implementation::AdapterPatch
            prepend patch
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
    # steep:ignore:end
  end
end
