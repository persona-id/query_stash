# frozen_string_literal: true

module QueryStash
  class Railtie < Rails::Railtie
    config.before_configuration do
      config.query_stash = ActiveSupport::OrderedOptions.new.update(
        raise_on_cache_error: Rails.env.development? || Rails.env.test?
      )
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

    config.to_prepare do |_app|
      ActiveSupport.on_load(:active_record) do
        require_relative "active_record"

        extend QueryStash::ActiveRecord::ContextMethods

        # This pattern is stolen from the database_rewinder gem
        ::ActiveRecord::ConnectionAdapters::AbstractAdapter.descendants.each do |adapter|
          # In order not to avoid touching AbstractMysqlAdapter
          next if adapter.descendants.any?

          adapter.prepend(QueryStash::ActiveRecord::AdapterPatch)
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
