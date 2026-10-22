# frozen_string_literal: true

require "digest"
require_relative "base"
require_relative "registry/sql"

module QueryStash
  class ActiveRecord < Base
    # What the patches ask of Rails' own objects.
    #
    # @rbs!
    #   # An ActiveRecord adapter, up to Rails 8.1.
    #   interface _InternalExecQueryAdapter
    #     def internal_exec_query: (String sql, ?String name, ?Array[untyped] binds, **untyped) -> ::ActiveRecord::Result
    #   end
    #
    #   # An ActiveRecord adapter, from Rails 8.2.
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

    # Enables the stash for the duration of each request.
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

    # Patch wraps queries run through `internal_exec_query` (rails 7.2 to 8.1).
    # See `QueryStash::ActiveRecord.implementation`.
    module InternalExecQuery
      # @rbs module-self _InternalExecQueryAdapter
      module AdapterPatch
        # @rbs override
        def internal_exec_query(sql, name = "SQL", binds = [], ...) # steep:ignore UnannotatedEmptyCollection
          stash = QueryStash::ActiveRecord[Rails.application] #: QueryStash::ActiveRecord & Stash
          stash.wrap(sql, binds) { super(sql, name, binds, ...) }
        end
      end

      # @rbs module-self QueryStash::ActiveRecord
      module Stash
        # Runs the query through the stash, or just yields when the stash is off or the query isn't
        # stashable.
        #: (String sql, Array[untyped]? binds) { () -> ::ActiveRecord::Result } -> ::ActiveRecord::Result
        def wrap(sql, binds)
          rule = rule_for(sql, has_binds: binds&.any?)
          return yield unless rule

          cached_result = read(rule, sql)
          return cached_result unless cached_result.nil?

          write(rule, yield, sql)
        end
      end
    end

    # Rails 8.2 runs queries as intents: the adapter's `execute_intent` runs one and hands its raw result
    # back to the intent, which turns it into an ActiveRecord::Result in `QueryIntent#cast_result`.
    module ExecuteIntent
      # @rbs module-self _IntentAdapter
      module AdapterPatch
        #: (_QueryIntent intent) -> untyped
        def execute_intent(intent)
          stash = QueryStash::ActiveRecord[Rails.application] #: QueryStash::ActiveRecord & Stash
          cached_result = stash.read_intent(intent)
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
          stash = QueryStash::ActiveRecord[Rails.application] #: QueryStash::ActiveRecord & Stash
          super.tap { |result| stash.write_intent(self, result) }
        end
      end

      # @rbs module-self QueryStash::ActiveRecord
      module Stash
        # @rbs @intent_rules: ObjectSpace::WeakMap[_QueryIntent, Registry::Rule]

        # The rule each intent that missed the stash is to be stored under, until its result is cast.
        #: (QueryStash::ActiveRecord stash) -> void
        def self.extended(stash)
          stash.instance_variable_set(:@intent_rules, ObjectSpace::WeakMap.new)
        end

        # The stashed result of an intent (see AdapterPatch), or nil: when there is none, the intent is
        # remembered for `write_intent` to store its result.
        #: (_QueryIntent intent) -> ::ActiveRecord::Result?
        def read_intent(intent)
          rule = rule_for(intent.raw_sql, has_binds: intent.has_binds?)
          return unless rule

          read(rule, intent.raw_sql).tap { |cached_result| @intent_rules[intent] = rule if cached_result.nil? }
        end

        # Stores the result of an intent `read_intent` found nothing for.
        #: (_QueryIntent intent, ::ActiveRecord::Result result) -> untyped
        def write_intent(intent, result)
          rule = @intent_rules[intent]
          return unless rule

          @intent_rules.delete(intent)
          write(rule, result, intent.raw_sql)
        end
      end
    end

    # The implementation for the Rails in use: only to be asked once ActiveRecord is loaded.
    #: () -> (singleton(InternalExecQuery) | singleton(ExecuteIntent))
    def self.implementation
      if ::ActiveRecord::ConnectionAdapters.const_defined?(:QueryIntent)
        # Rails 8.2 or higher
        ExecuteIntent
      else
        # Rails 8.1 or lower
        InternalExecQuery
      end
    end

    # The rule the query is stashed under, or nil when it isn't to be stashed: the stash is off, it has
    # binds (not supported), it is not a SELECT, or no rule matches it.
    #: (String sql, ?has_binds: bool?) -> Registry::Rule?
    def rule_for(sql, has_binds: false)
      return unless stashing?
      return if has_binds
      return unless CACHEABLE_SQL_REGEX.match?(sql)

      rule = registry.match_rule(sql)
      rule if rule && (rule.enabled.nil? || rule.enabled.call)
    end

    #: (String sql) -> String
    def cache_key_for(sql)
      # Note that the SQL is already normalized by the adapter here.
      #
      # Also note that SQL comments are applied AFTER this since
      # this module is prepended.
      "v1:#{::ActiveRecord::Base.current_shard}:#{Digest::SHA256.hexdigest(sql)}"
    end

    private

    #: () -> Registry::Sql
    def build_registry
      Registry::Sql.new
    end
  end
end
