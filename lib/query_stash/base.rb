# frozen_string_literal: true

require_relative "file_store"

module QueryStash
  module Base
    class Registry
      Rule = Data.define(
        :selector,
        :name,
        :ttl_seconds,
        :ttl_jitter_seconds,
        :on_cache_hit,
        :on_cache_miss,
        :on_cache_skip,
        :enabled,
        :store
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
        on_cache_skip: nil,
        enabled: nil,
        store: nil
      )
        raise "Rule name is required" if name.blank?

        raise "Rule name #{name.inspect} is already taken" if @rules.any? { |r| r.name == name }

        @rules << Rule.new(
          selector: selector,
          name: name,
          ttl_seconds: ttl_seconds,
          ttl_jitter_seconds: ttl_jitter_seconds,
          on_cache_hit: on_cache_hit,
          on_cache_miss: on_cache_miss,
          on_cache_skip: on_cache_skip,
          enabled: enabled,
          store: store
        )
      end

      def delete_rule(name)
        @rules.delete_if { |r| r.name == name }
      end

      # Selector / options / collection-based lookup
      def match_rule(selector)
        @rules.detect do |rule|
          value_matches_pattern?(selector, rule.selector)
        end
      end

      private

      # Pattern matching for hashes.
      #
      # `pattern` is a subset / pattern-form of `full`:
      # - wildcards and special values are interpreted via value_matches_pattern?
      #
      def hash_matches_pattern?(full, pattern)
        pattern.all? do |k, expected|
          full.key?(k) && value_matches_pattern?(full[k], expected)
        end
      end

      # Pattern semantics:
      #
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

    attr_writer :cache

    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new(size: 128.megabytes, compress: true)
    end

    def file_store(cache_path, lock_path:)
      QueryStash::FileStore.new("query-stash-#{prefix}", cache_path, lock_path: lock_path)
    end

    def cache_for(rule)
      rule.store || cache
    end

    def cache_usage_bytes(rule = nil)
      cache_obj = rule ? cache_for(rule) : cache
      if cache_obj.respond_to?(:redis)
        @_redis_cache_stats ||= {}
        updated_at, stats = @_redis_cache_stats[cache_obj]
        # Only update cache stats once every minute to avoid excessive Redis calls
        if updated_at.nil? || updated_at < 1.minute.ago
          @_redis_cache_stats[cache_obj] = [Time.current, stats]
          stats = cache_obj.stats
          @_redis_cache_stats[cache_obj] = [Time.current, stats]
        end

        stats&.fetch("used_memory", nil)&.to_i
      elsif cache_obj.is_a?(QueryStash::FileStore)
        cache_obj.usage_bytes
      else
        # WARNING: relies on internal ActiveSupport::Cache::MemoryStore API
        cache_obj.instance_variable_get(:@cache_size)
      end
    end

    def registry
      @_registry ||= Registry.new
    end

    def configure
      yield registry
    end

    def rescue_cache_error(&block)
      block.call
    rescue Errno::ENOENT
      # file store cache may raise these errors when there's a conflict with the
      # cleanup making files disappear.
      nil
    rescue StandardError => e
      raise e if Rails.application.config.query_stash.raise_on_cache_error

      ActiveSupport.error_reporter.report(e, handled: true)
    end
  end
end
