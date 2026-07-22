# frozen_string_literal: true

require "digest"
require "open3"
require "mongo"
require "active_support"
require "active_support/cache"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/json"
require "active_support/core_ext/numeric/time"
require "query_stash"

module QueryStash
  module Mongo
    extend self

    # ---------------- Registry + Rules ----------------
    class Registry
      Rule = Struct.new(
        :selector,
        :name,
        :ttl_seconds,
        :ttl_jitter_seconds,
        :on_cache_hit,
        :on_cache_miss,
        :on_cache_skip,
        keyword_init: true
      )

      attr_reader :rules

      def initialize
        @rules = []
      end

      def add_rule(
        selector, # required
        name:,
        ttl_seconds:,
        ttl_jitter_seconds:,
        on_cache_hit: nil,
        on_cache_miss: nil,
        on_cache_skip: nil
      )
        raise "Rule name is required" if name.blank?

        raise "Rule name #{name.inspect} is already taken" if @rules.any? { |r| r.name == name }

        %i[
          collection_name
          filter
          limit
          skip
          sort
          projection
          pipeline
        ].each { |key| selector.key?(key) || raise("Rule selector must contain :#{key}") }

        @rules << Rule.new(
          selector: selector,
          name: name,
          ttl_seconds: ttl_seconds,
          ttl_jitter_seconds: ttl_jitter_seconds,
          on_cache_hit: on_cache_hit,
          on_cache_miss: on_cache_miss,
          on_cache_skip: on_cache_skip
        )
      end

      def delete_rule(name)
        @rules.delete_if { |r| r.name == name }
      end

      # Selector / options / collection-based lookup
      def match_rule(selector)
        @rules.detect do |rule|
          hash_matches_pattern?(selector, rule.selector)
        end
      end

      private

      # Pattern matching for hashes.
      #
      # `pattern` is a subset / pattern-form of `full`:
      # - wildcards and special values are interpreted via value_matches_pattern?
      #
      def hash_matches_pattern?(full, pattern)
        return false unless full.is_a?(Hash)

        pattern.all? do |k, expected|
          full.key?(k) && value_matches_pattern?(full[k], expected)
        end
      end

      # Pattern semantics:
      #
      # - ANY sentinel:
      #     pattern.equal?(ANY) => match anything as long as the key exists
      # - Proc:
      #     pattern.call(actual) must be truthy
      # - Regexp:
      #     actual.to_s must match pattern
      # - Hash:
      #     pattern is a nested hash pattern, recurse
      # - Array:
      #     pattern is a "prefix" array pattern:
      #       - pattern length <= actual length
      #       - each element is matched via value_matches_pattern?
      # - Fallback:
      #     actual == pattern
      #
      def value_matches_pattern?(actual, pattern)
        # Wildcard – anything goes (key presence already checked by caller)
        return true if pattern.equal?(ANY)

        # Proc – fully custom predicate (Note: ANY is not a Proc)
        return !!pattern.call(actual) if pattern.respond_to?(:call)

        # Regexp – string-like match
        return pattern.match?(actual.to_s) if pattern.is_a?(Regexp)

        # Hash – recursive hash pattern
        return hash_matches_pattern?(actual, pattern) if pattern.is_a?(Hash) && actual.is_a?(Hash)

        # Array – element-wise prefix pattern
        if pattern.is_a?(Array) && actual.is_a?(Array)
          return false if pattern.length > actual.length

          return pattern.each_with_index.all? do |pat_elem, idx|
            value_matches_pattern?(actual[idx], pat_elem)
          end
        end

        # Fallback: strict equality
        actual == pattern
      end
    end

    # ---------------- Mongo driver patches ----------------
    module BasePatch
      def with_query_stash(&block)
        QueryStash.state.wrap(query_stash_mongo_enabled: true, &block)
      end

      def without_query_stash(&block)
        QueryStash.state.wrap(query_stash_mongo_enabled: false, &block)
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

    # ---------------- Constants ----------------
    # Wildcard sentinel for selector patterns
    ANY = Object.new.freeze

    attr_writer :cache

    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new(size: 128.megabytes, compress: true)
    end

    def file_store(cache_path, lock_path:)
      store = ActiveSupport::Cache::FileStore.new(cache_path)
      # set up evictor thread, as file store grows unbounded otherwise
      Thread.start(store) do |file_cache|
        Thread.current.name = "query-stash-mongo-evictor"
        loop do
          sleep 5 * 60 # 5 min
          File.open(lock_path, File::RDWR | File::CREAT) do |f|
            file_cache.cleanup if f.flock(File::LOCK_EX | File::LOCK_NB)
          end
          sleep rand # jitter
        rescue Interrupt
          break
        rescue StandardError => e
          # failed to clean up the file cache
          ActiveSupport.error_reporter.report(e, handled: true)
        end
      end
      store
    end

    def cache_usage_bytes
      cache_obj = cache
      if cache_obj.respond_to?(:redis)
        # Only update cache stats once every minute to avoid excessive Redis calls
        if @_cache_stats_last_updated_at.blank? || @_cache_stats_last_updated_at < 1.minute.ago
          @_cache_stats_last_updated_at = Time.current
          @_cache_stats = cache_obj.stats
        end

        @_cache_stats&.fetch("used_memory", nil)&.to_i
      elsif cache_obj.is_a?(ActiveSupport::Cache::FileStore)
        # Only update cache stats once every 30 seconds to avoid excessive STAT syscalls
        if @file_cache_stats_last_updated_at.blank? || @file_cache_stats_last_updated_at < 30.seconds.ago
          @file_cache_stats_last_updated_at = Time.current
          @file_cache_stats = nil
        end

        @file_cache_stats ||= begin
          o, e, s = Open3.capture3("du", cache_obj.cache_path, "-bs")

          if s.success?
            # ex: 128234328   path/to/dir
            o.split(/\W+/).first.to_i
          else
            cache_obj.logger&.error(e)
            0
          end
        end
      else
        # WARNING: relies on internal ActiveSupport::Cache::MemoryStore API
        cache_obj.instance_variable_get(:@cache_size)
      end
    end

    def registry
      @registry ||= Registry.new
    end

    def configure
      yield registry
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
      cache_obj = cache

      rescue_cache_error do
        cached_result = cache_obj.read(cache_key)
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

    def rescue_cache_error(&block)
      block.call
    rescue StandardError => e
      raise e if QueryStash.raise_errors

      ActiveSupport.error_reporter.report(e, handled: true)
    end
  end
end

Mongo.extend(QueryStash::Mongo::BasePatch)

Mongo::Collection::View::Iterable.prepend(
  QueryStash::Mongo::AdapterPatch
)
