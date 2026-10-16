# frozen_string_literal: true

require "digest"
require "active_record"
require "query_stash/base"

module QueryStash
  module ActiveRecord
    include QueryStash::Base

    extend self

    CACHEABLE_SQL_REGEX = /\ASELECT/i
    private_constant :CACHEABLE_SQL_REGEX

    class SqlRegistry < Registry
      def add_rule(regex, ...)
        raise "Regex must be a Regexp, got #{regex.class}" if regex.class != Regexp

        super
      end
    end

    module ContextMethods
      def with_query_stash(&block)
        QueryStash.state.wrap(query_stash_active_record_enabled: true, &block)
      end

      def without_query_stash(&block)
        QueryStash.state.wrap(query_stash_active_record_enabled: false, &block)
      end
    end

    module AdapterPatch
      def internal_exec_query(sql, name = "SQL", binds = [], ...)
        if QueryStash.state[:query_stash_active_record_enabled]
          QueryStash::ActiveRecord.wrap(sql, binds) do
            super(sql, name, binds, ...)
          end
        else
          super
        end
      end
    end

    def prefix = "active-record"

    def registry
      @_registry ||= SqlRegistry.new
    end

    def wrap(sql, binds)
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

    def cache_key_for(sql)
      # Note that the SQL is already normalized by the adapter here.
      #
      # Also note that SQL comments are applied AFTER this since
      # this module is prepended.
      "v1:#{::ActiveRecord::Base.current_shard}:#{Digest::SHA256.hexdigest(sql)}"
    end
  end
end

ActiveSupport.on_load(:active_record) do
  extend QueryStash::ActiveRecord::ContextMethods

  # This pattern is stolen from the database_rewinder gem
  ActiveRecord::ConnectionAdapters::AbstractAdapter.descendants.each do |adapter|
    # In order not to avoid touching AbstractMysqlAdapter
    next if adapter.descendants.any?

    adapter.prepend(QueryStash::ActiveRecord::AdapterPatch)
  end
end
