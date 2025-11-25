# frozen_string_literal: true

require "digest"
require "active_record"
require "query_stash"

module QueryStash
  module ActiveRecord
    extend self

    # Public: Registry is the DSL for rules
    class Registry
      Rule = Struct.new(
        :regex,
        :name,
        :ttl_seconds,
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
        regex,
        name:,
        ttl_seconds:,
        on_cache_hit: nil,
        on_cache_miss: nil,
        on_cache_skip: nil
      )
        raise "Rule name is required" if name.blank?

        raise "Rule name #{name.inspect} is already taken" if @rules.any? { |r| r.name == name }

        raise "Regex must be a Regexp, got #{regex.class}" if regex.class != Regexp

        @rules << Rule.new(
          regex: regex,
          name: name,
          ttl_seconds: ttl_seconds,
          on_cache_hit: on_cache_hit,
          on_cache_miss: on_cache_miss,
          on_cache_skip: on_cache_skip
        )
      end

      def delete_rule(name)
        @rules.delete_if { |r| r.name == name }
      end

      def match_rule(sql)
        @rules.detect { |r| r.regex.match?(sql) }
      end
    end

    # ---------- ActiveRecord patches ----------
    module BasePatch
      def with_query_stash(&block)
        old = Thread.current[:query_stash_active_record_enabled]
        Thread.current[:query_stash_active_record_enabled] = true
        block.call
      ensure
        Thread.current[:query_stash_active_record_enabled] = old
      end

      def without_query_stash(&block)
        old = Thread.current[:query_stash_active_record_enabled]
        Thread.current[:query_stash_active_record_enabled] = false
        block.call
      ensure
        Thread.current[:query_stash_active_record_enabled] = old
      end
    end

    module AdapterPatch
      def exec_query(sql, name = "SQL", binds = [], prepare: false)
        if Thread.current[:query_stash_active_record_enabled]
          QueryStash::ActiveRecord.wrap(sql, binds) do
            super(sql, name, binds, prepare: prepare)
          end
        else
          super(sql, name, binds, prepare: prepare)
        end
      end
    end

    CACHE_STORE_SIZE = 128 * 1024 * 1024
    private_constant :CACHE_STORE_SIZE

    CACHEABLE_SQL_REGEX = /\ASELECT/i
    private_constant :CACHEABLE_SQL_REGEX

    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new(size: CACHE_STORE_SIZE)
    end

    def registry
      @registry ||= Registry.new
    end

    def configure
      yield registry
    end

    def wrap(sql, binds)
      # Currently does not support binds
      return yield if binds.present?

      return yield unless CACHEABLE_SQL_REGEX.match?(sql)

      rule = registry.match_rule(sql)
      return yield unless rule

      cache_key = cache_key_for(sql)

      cached_result = cache.read(cache_key)
      if cached_result
        rule.on_cache_hit&.call(rule, cached_result)
        return cached_result
      end

      result = yield

      begin
        ttl_seconds =
          if rule.ttl_seconds.respond_to?(:call)
            rule.ttl_seconds.call(result).to_i
          else
            rule.ttl_seconds.to_i
          end

        if ttl_seconds.positive?
          rule.on_cache_miss&.call(rule, result)
          cache.write(cache_key, result, expires_in: ttl_seconds)
        else
          rule.on_cache_skip&.call(rule, result)
        end
      rescue StandardError => e
        raise e if QueryStash.raise_errors

        ::ActiveRecord::Base.logger&.error("Encountered error in QueryStash::ActiveRecord for rule #{rule.name}: #{e.message}")
      end

      result
    end

    private

    def cache_key_for(sql)
      # Note that the SQL is already normalized by the adapter here.
      #
      # Also note that Marginalia comments are applied AFTER this since
      # this module is prepended.
      "v1:#{::ActiveRecord::Base.current_shard}:#{Digest::SHA256.hexdigest(sql)}"
    end
  end
end

ActiveSupport.on_load(:active_record) do
  extend QueryStash::ActiveRecord::BasePatch

  # This pattern is stolen from the database_rewinder gem
  ActiveRecord::ConnectionAdapters::AbstractAdapter.descendants.each do |adapter|
    # In order not to avoid touching AbstractMysqlAdapter
    next if adapter.descendants.any?

    adapter.prepend(QueryStash::ActiveRecord::AdapterPatch)
  end
end
