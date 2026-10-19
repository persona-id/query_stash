# frozen_string_literal: true

require "digest"
require "query_stash/base"

module QueryStash
  module Mongo
    include QueryStash::Base

    extend self

    # ---------------- Constants ----------------
    # Wildcard sentinel for selector patterns
    ANY = Object.new.freeze

    class MongoFilterRegistry < Registry
      private

      # Pattern semantics:
      #
      # - ANY sentinel:
      #     pattern.equal?(ANY) => match anything as long as the key exists
      def value_matches_pattern?(actual, pattern)
        # Wildcard – anything goes (key presence already checked by caller)
        return true if pattern.equal?(ANY)

        super
      end
    end

    module ContextMethods
      def with_query_stash(&block)
        QueryStash.state.wrap(query_stash_mongo_enabled: true, &block)
      end

      def without_query_stash(&block)
        QueryStash.state.wrap(query_stash_mongo_enabled: false, &block)
      end
    end

    # Enables the stash for the duration of each request.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        ::Mongo.with_query_stash { @app.call(env) }
      end
    end

    module AdapterPatch
      def each
        if QueryStash.state[:query_stash_mongo_enabled]
          result = QueryStash::Mongo.wrap(self) do |cacheable:|
            # Avoid eager loading the entire result set unless this query actually
            # matches a cache rule. This can cause very quick OOMs
            # if it has to load a whole collection at once
            return super unless cacheable

            result = []
            # Have to explicitly pass in a block because otherwise, this will yield
            # and break processing immediately.
            super { |doc| result << doc }
            result
          end

          if block_given?
            # Use yield here to match the pattern in Mongo::Collection::View::Iterable#each
            result.each { |doc| yield doc } # rubocop:disable Style/ExplicitBlockArgument
          else
            result.to_enum
          end
        else
          super
        end
      end
    end

    def prefix = "mongo"

    def registry
      @_registry ||= MongoFilterRegistry.new
    end

    def wrap(view)
      # Based off of #cache_options in Mongo::Collection::View::Iterable
      # https://github.com/mongodb/mongo-ruby-driver/blob/v2.19.3/lib/mongo/collection/view/iterable.rb
      selector = {
        collection_name: view.collection.name,
        filter: view.filter,
        limit: view.options[:limit],
        skip: view.options[:skip],
        sort: view.options[:sort],
        projection: view.options[:projection],
        pipeline: view.respond_to?(:pipeline) ? view.pipeline : nil
      }

      rule = registry.match_rule(selector)
      return yield(cacheable: false) unless rule

      cache_key = cache_key_for(view.database.name, selector)
      cache_obj = cache_for(rule)

      rescue_cache_error do
        cached_result = ActiveSupport::Notifications.instrument(
          "cache_read.query_stash",
          adapter: :mongo,
          rule: rule.name
        ) do |payload|
          value = cache_obj.read(cache_key)
          payload[:hit] = !value.nil?
          value
        end
        # Results are always Arrays (never nil), so nil unambiguously means a miss.
        unless cached_result.nil?
          rule.on_cache_hit&.call(rule, cached_result)
          return cached_result
        end
      end

      result = yield(cacheable: true)

      rescue_cache_error do
        ttl_seconds =
          if rule.ttl_seconds.respond_to?(:call)
            rule.ttl_seconds.call(result).to_i
          else
            rule.ttl_seconds.to_i
          end

        ttl_jitter_seconds =
          if rule.ttl_jitter_seconds.respond_to?(:call)
            rule.ttl_jitter_seconds.call(result).to_i
          else
            rule.ttl_jitter_seconds.to_i
          end

        if ttl_seconds.positive?
          rule.on_cache_miss&.call(rule, result)
          cache_obj.write(cache_key, result, expires_in: ttl_seconds + rand(ttl_jitter_seconds))
        else
          rule.on_cache_skip&.call(rule, result)
        end
      end

      result
    end

    private

    # Based off of #cache_key from Mongo::QueryCache
    # https://github.com/mongodb/mongo-ruby-driver/blob/master/lib/mongo/query_cache.rb#L19
    def cache_key_for(database_name, selector)
      raw = [
        selector[:collection_name],
        selector[:filter],
        selector[:limit],
        selector[:skip],
        selector[:sort],
        selector[:projection],
        selector[:pipeline]
      ].to_json

      "v1:#{database_name}:#{Digest::SHA256.hexdigest(raw)}"
    end
  end
end
