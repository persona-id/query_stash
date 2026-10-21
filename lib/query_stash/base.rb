# frozen_string_literal: true

require "concurrent/map"
require_relative "file_store"

module QueryStash
  class Base
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
      ) do
        def ttl_seconds_for(result)
          if ttl_seconds.respond_to?(:call)
            ttl_seconds.call(result).to_i
          else
            ttl_seconds.to_i
          end
        end

        def ttl_jitter_seconds_for(result)
          if ttl_jitter_seconds.respond_to?(:call)
            ttl_jitter_seconds.call(result).to_i
          else
            ttl_jitter_seconds.to_i
          end
        end
      end

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

    # Where `enable!` and `disable!` keep what they set, when `config.query_stash.isolated_state` is
    # not given: a hash in a thread variable, so every fiber of a thread sees the same values and
    # other threads see none.
    #
    # An isolated state is any object that responds to `[]`, `[]=`, `key?` and `delete`, like
    # `ActiveSupport::IsolatedExecutionState`.
    class ThreadVariableState
      THREAD_VARIABLE = :query_stash_state

      def [](key)
        values[key]
      end

      def []=(key, value)
        values[key] = value
      end

      def key?(key)
        values.key?(key)
      end

      def delete(key)
        values.delete(key)
      end

      private

      def values
        Thread.current.thread_variable_get(THREAD_VARIABLE) ||
          Thread.current.thread_variable_set(THREAD_VARIABLE, {})
      end
    end

    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@instances, Concurrent::Map.new)
      end

      def [](app)
        @instances.fetch(app)
      end

      # Makes `stash` the instance `app` uses.
      def set(app, stash)
        @instances[app] = stash
      end
    end

    attr_reader :registry, :cache, :enabled

    # `config` is the Rails application's config; the stash reads `config.query_stash`.
    def initialize(config)
      options = config.query_stash

      @enabled = options.enabled
      @isolated_state = options.isolated_state || ThreadVariableState.new
      @raise_on_cache_error = options.raise_on_cache_error
      @registry = build_registry
      @cache = build_cache_store(*Array(options.cache_store))
      @redis_cache_stats = {}
    end

    def configure
      yield registry
    end

    # Turn the stash on or off for the block. Outside of either, it follows `enabled`.
    def enable!(&block)
      isolate(true, &block)
    end

    def disable!(&block)
      isolate(false, &block)
    end

    def cache_for(rule)
      rule.store || cache
    end

    def cache_usage_bytes(rule = nil)
      cache_obj = rule ? cache_for(rule) : cache
      if cache_obj.respond_to?(:redis)
        updated_at, stats = @redis_cache_stats[cache_obj]
        # Only update cache stats once every minute to avoid excessive Redis calls
        if updated_at.nil? || updated_at < 1.minute.ago
          @redis_cache_stats[cache_obj] = [Time.current, stats]
          stats = cache_obj.stats
          @redis_cache_stats[cache_obj] = [Time.current, stats]
        end

        stats&.fetch("used_memory", nil)&.to_i
      elsif cache_obj.is_a?(QueryStash::FileStore)
        cache_obj.usage_bytes
      else
        # WARNING: relies on internal ActiveSupport::Cache::MemoryStore API
        cache_obj.instance_variable_get(:@cache_size)
      end
    end

    private

    # Whether the stash is on for the current execution context: what `enable!` or `disable!` set
    # there, or else `enabled`.
    def stashing?
      @isolated_state.key?(self) ? @isolated_state[self] : enabled
    end

    # Sets the stash on or off in the isolated state for the block, then puts back what was there.
    def isolate(value)
      had_value = @isolated_state.key?(self)
      previous = @isolated_state[self]
      @isolated_state[self] = value
      yield
    ensure
      if had_value
        @isolated_state[self] = previous
      else
        @isolated_state.delete(self)
      end
    end

    def build_registry
      Registry.new
    end

    def rescue_cache_error(&block)
      block.call
    rescue Errno::ENOENT
      # file store cache may raise these errors when there's a conflict with the
      # cleanup making files disappear.
      nil
    rescue StandardError => e
      raise e if @raise_on_cache_error

      ActiveSupport.error_reporter.report(e, handled: true)
    end

    # `:file_store` gets a QueryStash::FileStore, with the adapter's prefix on the directory's
    # basename so each adapter keeps its own directory: "tmp/stash" becomes "tmp/active-record-stash".
    def build_cache_store(store, *parameters)
      return ActiveSupport::Cache.lookup_store(store, *parameters) unless store == :file_store

      cache_path, options = parameters

      QueryStash::FileStore.new(
        File.join(File.dirname(cache_path), "#{prefix}-#{File.basename(cache_path)}"),
        **options.to_h
      )
    end
  end
end
