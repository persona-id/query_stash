# frozen_string_literal: true

require "digest"
require_relative "base"

module QueryStash
  class ActiveRecord < Base
    CACHEABLE_SQL_REGEX = /\ASELECT/i
    private_constant :CACHEABLE_SQL_REGEX

    class SqlRegistry < Registry
      def add_rule(regex, ...)
        raise "Regex must be a Regexp, got #{regex.class}" if regex.class != Regexp

        super
      end
    end

    # Enables the stash for the duration of each request. `application` is the Rails application the
    # middleware stack belongs to; `app` is the next middleware.
    class Middleware
      def initialize(app, application)
        @app = app
        @application = application
      end

      def call(env)
        QueryStash::ActiveRecord[@application].enable! { @app.call(env) }
      end
    end

    module AdapterPatch
      def internal_exec_query(sql, name = "SQL", binds = [], ...)
        QueryStash::ActiveRecord[Rails.application].wrap(sql, binds) { super(sql, name, binds, ...) }
      end
    end

    def prefix = "active-record"

    # Runs the query through the stash, or just yields when the stash is off or the query isn't
    # stashable.
    def wrap(sql, binds)
      return yield unless stashing?

      # Currently does not support binds
      return yield if binds.present?

      return yield unless CACHEABLE_SQL_REGEX.match?(sql)

      rule = registry.match_rule(sql)
      return yield unless rule

      return yield unless rule.enabled.nil? || rule.enabled.call

      cache_key = cache_key_for(sql)
      cache_obj = cache

      rescue_cache_error do
        cached_result = ActiveSupport::Notifications.instrument(
          "cache_read.query_stash",
          adapter: :active_record,
          rule: rule.name
        ) do |payload|
          value = cache_obj.read(cache_key)
          payload[:hit] = !value.nil?
          value
        end
        # Results are always ActiveRecord::Result (never nil), so nil means a miss.
        unless cached_result.nil?
          ActiveSupport::Notifications.instrument("cache_hit.query_stash", adapter: :active_record, rule: rule.name)
          rule.on_cache_hit&.call(rule, cached_result)
          return cached_result
        end
      end

      result = yield

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

    def build_registry
      SqlRegistry.new
    end

    def cache_key_for(sql)
      # Note that the SQL is already normalized by the adapter here.
      #
      # Also note that SQL comments are applied AFTER this since
      # this module is prepended.
      "v1:#{::ActiveRecord::Base.current_shard}:#{Digest::SHA256.hexdigest(sql)}"
    end
  end
end
