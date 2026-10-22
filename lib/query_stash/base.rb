# frozen_string_literal: true

require "concurrent/map"
require_relative "registry"

module QueryStash
  class Base
    # Where `enable!` and `disable!` keep what they set, when no `isolated_state` is
    # given: a hash in a thread variable, so every fiber of a thread sees the same values and
    # other threads see none.
    #
    # An isolated state is any object that responds to `[]`, `[]=`, `key?` and `delete`, like
    # `ActiveSupport::IsolatedExecutionState`.
    class ThreadVariableState
      THREAD_VARIABLE = :query_stash_state #: Symbol

      #: (untyped key) -> untyped
      def [](key)
        values[key]
      end

      #: (untyped key, untyped value) -> untyped
      def []=(key, value)
        values[key] = value
      end

      #: (untyped key) -> bool
      def key?(key)
        values.key?(key)
      end

      #: (untyped key) -> untyped
      def delete(key)
        values.delete(key)
      end

      private

      #: () -> Hash[untyped, untyped]
      def values
        Thread.current.thread_variable_get(THREAD_VARIABLE) ||
          Thread.current.thread_variable_set(THREAD_VARIABLE, {})
      end
    end

    # Used when no `instrumenter` is given: runs the block and tells no one.
    class NullInstrumenter
      #: (String _name, ?Hash[Symbol, untyped] payload) ?{ (Hash[Symbol, untyped]) -> untyped } -> untyped
      def instrument(_name, payload = {})
        yield payload if block_given?
      end
    end

    # Used when no `error_reporter` is given.
    class WarnErrorReporter
      #: (Exception error, ?handled: bool) -> void
      def report(error, handled: true) # rubocop:disable Lint/UnusedMethodArgument
        warn("QueryStash: #{error.class}: #{error.message}")
      end
    end

    class << self
      # @rbs self.@instances: Concurrent::Map[untyped, untyped]

      #: (Class subclass) -> void
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@instances, Concurrent::Map.new)
      end

      #: (untyped app) -> instance
      def [](app)
        @instances.fetch(app)
      end

      #: (untyped app) -> bool
      def key?(app)
        !@instances.fetch(app, nil).nil?
      end

      # Makes `stash` the instance `app` uses.
      #: (untyped app, instance stash) -> instance
      def set(app, stash)
        @instances[app] = stash
      end
    end

    # @rbs @enabled: bool
    # @rbs @isolated_state: _IsolatedState
    # @rbs @instrumenter: _Instrumenter
    # @rbs @error_reporter: _ErrorReporter
    # @rbs @raise_on_cache_error: bool
    # @rbs @registry: Registry
    # @rbs @cache: _CacheStore
    # @rbs @adapter: Symbol

    attr_reader :registry #: Registry

    attr_reader :cache #: _CacheStore

    attr_reader :enabled #: bool

    # What each stash is given:
    #
    # - `enabled`: whether queries are stashed outside of `enable!` and `disable!`.
    # - `isolated_state`: where those keep what they set. By default, a thread variable.
    # - `instrumenter`: told about what the stash does. By default, no one.
    # - `error_reporter`: told about the errors it handles. By default, a warning on stderr.
    # - `raise_on_cache_error`: raise the errors of the cache store, instead of reporting them.
    # - `cache_store`: where results are kept, any object that responds to `read(key)`,
    #   `write(key, value, expires_in:)` and `clear`, like an ActiveSupport cache store.
    #
    # @rbs cache_store: _CacheStore
    # @rbs enabled: bool
    # @rbs isolated_state: _IsolatedState?
    # @rbs instrumenter: _Instrumenter?
    # @rbs error_reporter: _ErrorReporter?
    # @rbs raise_on_cache_error: bool
    # @rbs return: void
    def initialize(
      cache_store:,
      enabled: true,
      isolated_state: nil,
      instrumenter: nil,
      error_reporter: nil,
      raise_on_cache_error: false
    )
      @enabled = enabled
      @isolated_state = isolated_state || ThreadVariableState.new
      @instrumenter = instrumenter || NullInstrumenter.new
      @error_reporter = error_reporter || WarnErrorReporter.new
      @raise_on_cache_error = raise_on_cache_error
      @registry = build_registry
      @cache = cache_store
      @adapter = self.class.name.to_s.split("::").last.to_s.gsub(/(?<=[a-z])(?=[A-Z])/, "_").downcase.to_sym
    end

    #: () { (Registry registry) -> void } -> void
    def configure
      yield registry
    end

    # Turn the stash on or off for the block. Outside of either, it follows `enabled`.
    #: [T] () { () -> T } -> T
    def enable!(&block)
      isolate(true, &block)
    end

    #: [T] () { () -> T } -> T
    def disable!(&block)
      isolate(false, &block)
    end

    #: (Registry::Rule rule) -> _CacheStore
    def cache_for(rule)
      rule.store || cache
    end

    # ---------------- What an adapter's stash provides ----------------
    #
    # An adapter patches whatever runs its queries so that it asks its stash, in this order:
    #
    # 1. `rule_for(*args)`: is this query stashed, and under which rule? When it isn't, the query just runs.
    # 2. `read(rule, *args)`: is its result in the stash? When it is, that is the result.
    # 3. `write(rule, result, *args)`: otherwise it runs, and its result goes in the stash.
    #
    # `*args` is whatever the adapter has that identifies a query (the SQL, a driver's view, ...). It is the
    # same for `read`, `write` and `cache_key_for`. `rule_for` may be given more, for what only decides
    # whether to stash.
    #
    # A stash gets `read` and `write` from here, which keep the reading and writing of the cache store, the
    # instrumentation and the handling of errors in one place. It has to define `rule_for` and
    # `cache_key_for`, and can override the others.

    # The rule of the registry the query is to be stashed under, or nil when it isn't to be: the stash is off
    # (see `stashing?`), the query is not one that can be, or no rule matches it.
    #: (*untyped) -> Registry::Rule?
    def rule_for(*)
      raise NotImplementedError, "#{self.class} must define #rule_for"
    end

    # The key the query's result is stored under.
    #: (*untyped) -> String
    def cache_key_for(*)
      raise NotImplementedError, "#{self.class} must define #cache_key_for"
    end

    # The result stored for the query, or nil when there is none (or the cache store failed: that is
    # reported, or raised when `raise_on_cache_error` is set). Emits `cache_read` and, on a hit,
    # `cache_hit`.
    #: (Registry::Rule rule, *untyped args) -> untyped
    def read(rule, *args)
      cache_key = cache_key_for(*args)
      cache_store = cache_for(rule)

      rescue_cache_error do
        cached_result = @instrumenter.instrument(
          "cache_read.query_stash",
          adapter: @adapter,
          rule: rule.name
        ) do |payload|
          cache_store.read(cache_key).tap do |value|
            payload[:hit] = !value.nil?
          end
        end

        # Results are never nil, so nil means a miss.
        unless cached_result.nil?
          @instrumenter.instrument("cache_hit.query_stash", adapter: @adapter, rule: rule.name)
          return cached_result
        end
      end

      nil
    end

    # Stores `result` for the query when the rule keeps results for any time (else it is skipped), and
    # returns it. Emits `cache_miss` or, when skipped, `cache_skip`.
    # A failure of the cache store is reported (or raised), and does not lose the result.
    #: (Registry::Rule rule, untyped result, *untyped args) -> untyped
    def write(rule, result, *args)
      ttl_seconds = rule.ttl_seconds_for(result)
      ttl_jitter_seconds = rule.ttl_jitter_seconds_for(result)

      rescue_cache_error do
        if ttl_seconds.positive?
          @instrumenter.instrument("cache_miss.query_stash", adapter: @adapter, rule: rule.name)
          cache_for(rule).write(cache_key_for(*args), result, expires_in: ttl_seconds + rand(ttl_jitter_seconds))
        else
          @instrumenter.instrument("cache_skip.query_stash", adapter: @adapter, rule: rule.name)
        end
      end

      result
    end

    private

    # Whether the stash is on for the current execution context: what `enable!` or `disable!` set
    # there, or else `enabled`.
    #: () -> bool
    def stashing?
      @isolated_state.key?(self) ? @isolated_state[self] : enabled
    end

    # Sets the stash on or off in the isolated state for the block, then puts back what was there.
    #: [T] (bool value) { () -> T } -> T
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

    #: () -> Registry
    def build_registry
      Registry.new
    end

    #: [T] () { () -> T } -> untyped
    def rescue_cache_error(&block)
      block.call
    rescue StandardError => e
      raise e if @raise_on_cache_error

      @error_reporter.report(e, handled: true)
    end
  end
end
