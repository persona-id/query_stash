# frozen_string_literal: true

require "digest"
require "open3"
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
        :ttl_jitter_seconds,
        :on_cache_hit,
        :on_cache_miss,
        :on_cache_skip,
        :enabled,
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
        ttl_jitter_seconds:,
        on_cache_hit: nil,
        on_cache_miss: nil,
        on_cache_skip: nil,
        enabled: nil
      )
        raise "Rule name is required" if name.blank?

        raise "Rule name #{name.inspect} is already taken" if @rules.any? { |r| r.name == name }

        raise "Regex must be a Regexp, got #{regex.class}" if regex.class != Regexp

        @rules << Rule.new(
          regex: regex,
          name: name,
          ttl_seconds: ttl_seconds,
          ttl_jitter_seconds: ttl_jitter_seconds,
          on_cache_hit: on_cache_hit,
          on_cache_miss: on_cache_miss,
          on_cache_skip: on_cache_skip,
          enabled: enabled
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
        QueryStash.state.wrap(query_stash_active_record_enabled: true, &block)
      end

      def without_query_stash(&block)
        QueryStash.state.wrap(query_stash_active_record_enabled: false, &block)
      end
    end

    module AdapterPatch
      def internal_exec_query(sql, name = "SQL", binds = [], prepare: false, **kwargs)
        if QueryStash.state[:query_stash_active_record_enabled]
          QueryStash::ActiveRecord.wrap(sql, binds) do
            super(sql, name, binds, prepare: prepare, **kwargs)
          end
        else
          super
        end
      end
    end

    CACHEABLE_SQL_REGEX = /\ASELECT/i
    private_constant :CACHEABLE_SQL_REGEX

    attr_writer :cache

    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new(size: 128.megabytes, compress: true)
    end

    def file_store(cache_path, lock_path:)
      store = ActiveSupport::Cache::FileStore.new(cache_path)
      # set up evictor thread, as file store grows unbounded otherwise
      Thread.start(store) do |file_cache|
        Thread.current.name = "query-stash-active-record-evictor"
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
        cached_result = cache_obj.read(cache_key)
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
      # Also note that Marginalia comments are applied AFTER this since
      # this module is prepended.
      "v1:#{::ActiveRecord::Base.current_shard}:#{Digest::SHA256.hexdigest(sql)}"
    end

    def rescue_cache_error(&block)
      block.call
    rescue StandardError => e
      raise e if QueryStash.raise_errors

      ActiveSupport.error_reporter.report(e, handled: true)
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
