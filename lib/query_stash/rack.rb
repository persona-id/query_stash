# frozen_string_literal: true

require "query_stash"

module QueryStash
  module Rack
    # Enables the stash for every adapter that has been required, for the
    # duration of each request.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        with_active_record do
          with_mongo do
            @app.call(env)
          end
        end
      end

      private

      def with_active_record(&block)
        return yield unless defined?(QueryStash::ActiveRecord)

        ::ActiveRecord::Base.with_query_stash(&block)
      end

      def with_mongo(&block)
        return yield unless defined?(QueryStash::Mongo)

        ::Mongo.with_query_stash(&block)
      end
    end
  end
end
