# frozen_string_literal: true

require "digest"
require_relative "base"

module QueryStash
  class ActiveRecord < Base
    # What the patches ask of Rails' own objects.
    #
    # @rbs!
    #   # An adapter, up to Rails 8.1.
    #   interface _InternalExecQueryAdapter
    #     def internal_exec_query: (String sql, ?String name, ?Array[untyped] binds, **untyped) -> ::ActiveRecord::Result
    #   end
    #
    #   # An adapter, from Rails 8.2.
    #   interface _IntentAdapter
    #     def execute_intent: (_QueryIntent intent) -> untyped
    #
    #     def cast_result: (untyped raw_result) -> ::ActiveRecord::Result
    #   end
    #
    #   # A query, from Rails 8.2.
    #   interface _QueryIntent
    #     def raw_sql: () -> String
    #
    #     def has_binds?: () -> bool
    #
    #     def deliver_result: (::ActiveRecord::Result result) -> untyped
    #
    #     def cast_result: () -> ::ActiveRecord::Result
    #   end

    CACHEABLE_SQL_REGEX = /\ASELECT/i #: Regexp
    private_constant :CACHEABLE_SQL_REGEX

    class SqlRegistry < Base::Registry
      # @rbs override
      def add_rule(regex, ...)
        raise Error, "Regex must be a Regexp, got #{regex.class}" if regex.class != Regexp

        super
      end
    end

    # Enables the stash for the duration of each request. `application` is the Rails application the
    # middleware stack belongs to; `app` is the next middleware.
    class Middleware
      # @rbs @app: _RackApp
      # @rbs @application: untyped

      #: (_RackApp app, untyped application) -> void
      def initialize(app, application)
        @app = app
        @application = application
      end

      #: (Hash[String, untyped] env) -> untyped
      def call(env)
        QueryStash::ActiveRecord[@application].enable! { @app.call(env) }
      end
    end

    # Rails 7.2 to 8.1 run every query through `internal_exec_query`.
    # @rbs module-self _InternalExecQueryAdapter
    module AdapterPatch
      # @rbs override
      def internal_exec_query(sql, name = "SQL", binds = [], ...) # steep:ignore UnannotatedEmptyCollection
        QueryStash::ActiveRecord[Rails.application].wrap(sql, binds) { super(sql, name, binds, ...) }
      end
    end

    # Rails 8.2 runs queries as intents: the adapter's `execute_intent` runs one and hands its raw result
    # back to the intent, which turns it into an ActiveRecord::Result in `QueryIntent#cast_result`. So a
    # stash hit is delivered to the intent in place of running it, and a miss is stored once the intent
    # has cast its result.
    # @rbs module-self _IntentAdapter
    module IntentAdapterPatch
      #: (_QueryIntent intent) -> untyped
      def execute_intent(intent)
        cached_result = QueryStash::ActiveRecord[Rails.application].read_intent(intent)
        return super if cached_result.nil?

        intent.deliver_result(cached_result)
      end

      private

      # A stash hit is delivered as the ActiveRecord::Result it already is.
      #: (untyped raw_result) -> ::ActiveRecord::Result
      def cast_result(raw_result)
        raw_result.is_a?(::ActiveRecord::Result) ? raw_result : super
      end
    end

    # @rbs module-self _QueryIntent
    module IntentPatch
      #: () -> ::ActiveRecord::Result
      def cast_result
        super.tap { |result| QueryStash::ActiveRecord[Rails.application].write_intent(self, result) }
      end
    end

    # @rbs @intent_rules: ObjectSpace::WeakMap[_QueryIntent, Base::Registry::Rule]

    # @rbs override
    def initialize(...)
      super
      # The rule each intent that missed the stash is to be stored under, until its result is cast.
      @intent_rules = ObjectSpace::WeakMap.new
    end

    # Runs the query through the stash, or just yields when the stash is off or the query isn't
    # stashable.
    #: (String sql, Array[untyped]? binds) { () -> ::ActiveRecord::Result } -> ::ActiveRecord::Result
    def wrap(sql, binds)
      rule = rule_for(sql, binds&.any?)
      return yield unless rule

      cached_result = read(rule, sql)
      return cached_result unless cached_result.nil?

      yield.tap { |result| write(rule, sql, result) }
    end

    # The stashed result of an intent (see IntentAdapterPatch), or nil: when there is none, the intent is
    # remembered for `write_intent` to store its result.
    #: (_QueryIntent intent) -> ::ActiveRecord::Result?
    def read_intent(intent)
      rule = rule_for(intent.raw_sql, intent.has_binds?)
      return unless rule

      read(rule, intent.raw_sql).tap { |cached_result| @intent_rules[intent] = rule if cached_result.nil? }
    end

    # Stores the result of an intent `read_intent` found nothing for.
    #: (_QueryIntent intent, ::ActiveRecord::Result result) -> untyped
    def write_intent(intent, result)
      rule = @intent_rules[intent]
      return unless rule

      @intent_rules.delete(intent)
      write(rule, intent.raw_sql, result)
    end

    private

    #: () -> SqlRegistry
    def build_registry
      SqlRegistry.new
    end

    # The rule the query is stashed under, or nil when it isn't to be stashed: the stash is off, it has
    # binds (not supported), it is not a SELECT, or no rule matches it.
    #: (String sql, bool? has_binds) -> Base::Registry::Rule?
    def rule_for(sql, has_binds)
      return unless stashing?
      return if has_binds
      return unless CACHEABLE_SQL_REGEX.match?(sql)

      rule = registry.match_rule(sql)
      rule if rule && (rule.enabled.nil? || rule.enabled.call)
    end

    #: (Base::Registry::Rule rule, String sql) -> ::ActiveRecord::Result?
    def read(rule, sql)
      cache_key = cache_key_for(sql)
      cache_store = cache_for(rule)

      rescue_cache_error do
        cached_result = @instrumenter.instrument(
          "cache_read.query_stash",
          adapter: :active_record,
          rule: rule.name
        ) do |payload|
          cache_store.read(cache_key).tap do |value|
            payload[:hit] = !value.nil?
          end
        end

        # Results are always ActiveRecord::Result (never nil), so nil means a miss.
        unless cached_result.nil?
          @instrumenter.instrument("cache_hit.query_stash", adapter: :active_record, rule: rule.name)
          rule.on_cache_hit&.call(rule, cached_result)
          return cached_result
        end
      end

      nil
    end

    #: (Base::Registry::Rule rule, String sql, ::ActiveRecord::Result result) -> untyped
    def write(rule, sql, result)
      ttl_seconds = rule.ttl_seconds_for(result)
      ttl_jitter_seconds = rule.ttl_jitter_seconds_for(result)

      rescue_cache_error do
        if ttl_seconds.positive?
          @instrumenter.instrument("cache_miss.query_stash", adapter: :active_record, rule: rule.name)
          rule.on_cache_miss&.call(rule, result)
          cache_for(rule).write(cache_key_for(sql), result, expires_in: ttl_seconds + rand(ttl_jitter_seconds))
        else
          @instrumenter.instrument("cache_skip.query_stash", adapter: :active_record, rule: rule.name)
          rule.on_cache_skip&.call(rule, result)
        end
      end
    end

    #: (String sql) -> String
    def cache_key_for(sql)
      # Note that the SQL is already normalized by the adapter here.
      #
      # Also note that SQL comments are applied AFTER this since
      # this module is prepended.
      "v1:#{::ActiveRecord::Base.current_shard}:#{Digest::SHA256.hexdigest(sql)}"
    end
  end
end
