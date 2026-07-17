# frozen_string_literal: true

require "tmpdir"
require "active_support/testing/time_helpers"
require "query_stash/active_record"

RSpec.describe QueryStash::ActiveRecord do
  def cache_key_for(sql)
    "v1:#{ActiveRecord::Base.current_shard}:#{Digest::SHA256.hexdigest(sql)}"
  end

  describe QueryStash::ActiveRecord::SqlRegistry do
    let(:registry) { described_class.new }

    describe "#add_rule" do
      it "adds rules with regex, name, callbacks, and blocks" do
        enabled = -> { true }
        registry.add_rule(/SELECT/, name: "test_rule", ttl_seconds: 60, ttl_jitter_seconds: 0, enabled: enabled)
        expect(registry.rules.length).to eq(1)
        expect(registry.rules.first.selector).to eq(/SELECT/)
        expect(registry.rules.first.name).to eq("test_rule")
        expect(registry.rules.first.enabled).to eq(enabled)

        callback = proc { |rule, result| }
        registry.add_rule(/UPDATE/, name: "callback_rule", on_cache_hit: callback, ttl_seconds: 60, ttl_jitter_seconds: 0)
        expect(registry.rules[1].on_cache_hit).to eq(callback)

        ttl_proc = proc { 60 }
        registry.add_rule(/INSERT/, name: "proc_rule", ttl_seconds: ttl_proc, ttl_jitter_seconds: 0)
        expect(registry.rules.last.ttl_seconds).to eq(ttl_proc)

        expect(registry.rules.length).to eq(3)
      end
    end

    describe "#delete_rule" do
      it "deletes rules by name and ignores unknown names" do
        registry.add_rule(/SELECT/, name: "test_rule", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(/INSERT/, name: "other_rule", ttl_seconds: 120, ttl_jitter_seconds: 0)

        registry.delete_rule("test_rule")
        expect(registry.rules.length).to eq(1)
        expect(registry.rules.map(&:name)).not_to include("test_rule")

        expect do
          registry.delete_rule("nonexistent")
        end.not_to(change { registry.rules.length })
      end
    end

    describe "#match_rule" do
      before do
        registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(/SELECT.*orders/, name: "order_queries", ttl_seconds: 120, ttl_jitter_seconds: 0)
      end

      it "returns the first matching rule, or nil" do
        expect(registry.match_rule("SELECT * FROM users WHERE id = 1").name).to eq("user_queries")
        expect(registry.match_rule("SELECT * FROM products")).to be_nil

        registry.add_rule(/SELECT/, name: "generic_select", ttl_seconds: 30, ttl_jitter_seconds: 0)
        expect(registry.match_rule("SELECT * FROM users").name).to eq("user_queries")
      end
    end
  end

  describe QueryStash::ActiveRecord::AdapterPatch do
    let(:adapter) do
      Class.new do
        def internal_exec_query(_sql, _name = "SQL", _binds = [], prepare: false, **_kwargs)
          "original_result"
        end
      end.prepend(described_class).new
    end

    before do
      QueryStash::ActiveRecord.registry.instance_variable_set(:@rules, [])
      QueryStash::ActiveRecord.cache.clear
      QueryStash::ActiveRecord.registry.add_rule(/SELECT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0)
    end

    context "when the stash is not enabled" do
      it "calls super without using the cache" do
        expect(adapter.internal_exec_query("SELECT * FROM users")).to eq("original_result")
        adapter.internal_exec_query("SELECT * FROM users")

        expect(QueryStash::ActiveRecord.cache.instance_variable_get(:@data)).to be_empty
      end
    end

    context "when the stash is enabled" do
      it "uses the cache for matching queries" do
        ActiveRecord::Base.with_query_stash do
          adapter.internal_exec_query("SELECT * FROM users")

          expect(QueryStash::ActiveRecord.cache.instance_variable_get(:@data).length).to eq(1)
        end
      end
    end
  end

  describe QueryStash::ActiveRecord::ContextMethods do
    describe "#with_query_stash" do
      it "enables the stash" do
        expect(QueryStash.state[:query_stash_active_record_enabled]).to be_nil

        ActiveRecord::Base.with_query_stash do
          expect(QueryStash.state[:query_stash_active_record_enabled]).to be(true)
        end

        expect(QueryStash.state[:query_stash_active_record_enabled]).to be_nil
      end
    end

    describe "#without_query_stash" do
      around do |example|
        ActiveRecord::Base.with_query_stash do
          example.run
        end
      end

      it "disables the stash" do
        expect(QueryStash.state[:query_stash_active_record_enabled]).to be(true)

        ActiveRecord::Base.without_query_stash do
          expect(QueryStash.state[:query_stash_active_record_enabled]).to be(false)
        end

        expect(QueryStash.state[:query_stash_active_record_enabled]).to be(true)
      end
    end
  end

  describe "the stash across spawned threads" do
    # Fake adapter that counts how many times it actually hits the "database"
    # (i.e. the underlying internal_exec_query without caching).
    let(:fake_adapter) do
      Class.new do
        attr_reader :db_call_count

        def initialize
          @db_call_count = 0
        end

        def internal_exec_query(_sql, _name = "SQL", _binds = [], prepare: false, **_kwargs)
          @db_call_count += 1
          "db_result"
        end
      end.prepend(QueryStash::ActiveRecord::AdapterPatch).new
    end

    # Stands in for an application context that child threads inherit.
    let(:inherited_state) do
      Class.new do
        def initialize
          @values = {}
        end

        def [](key)
          @values[key]
        end

        def wrap(**values)
          previous = @values.dup
          @values.merge!(values)
          yield
        ensure
          @values = previous
        end
      end.new
    end

    let(:sql) { "SELECT * FROM organizations WHERE organizations.id = 1" }

    before do
      described_class.cache.clear
      described_class.registry.instance_variable_set(:@rules, [])
      described_class.registry.add_rule(/SELECT.*organizations/, name: "test_org_rule", ttl_seconds: 60,
                                                                 ttl_jitter_seconds: 0)
    end

    after { QueryStash.state = nil }

    def query_in_parent_then_spawned_thread
      ActiveRecord::Base.with_query_stash do
        fake_adapter.internal_exec_query(sql)
        fake_adapter.internal_exec_query(sql)
        expect(fake_adapter.db_call_count).to eq(1)

        Thread.new { fake_adapter.internal_exec_query(sql) }.join
      end
    end

    it "does not carry the flag into spawned threads with the default state" do
      query_in_parent_then_spawned_thread

      expect(fake_adapter.db_call_count).to eq(2)
    end

    it "serves the spawned thread from the cache when the state is inherited" do
      QueryStash.state = inherited_state

      query_in_parent_then_spawned_thread

      expect(fake_adapter.db_call_count).to eq(1)
    end
  end

  describe ".cache" do
    it "returns a memoized ActiveSupport::Cache::MemoryStore instance" do
      expect(described_class.cache).to be_a(ActiveSupport::Cache::MemoryStore)
      expect(described_class.cache).to be(described_class.cache)
    end
  end

  describe ".cache=" do
    after { described_class.cache = nil }

    it "replaces the backing store" do
      store = ActiveSupport::Cache::MemoryStore.new
      described_class.cache = store

      expect(described_class.cache).to be(store)
    end
  end

  describe ".cache_usage_bytes" do
    after { described_class.cache = nil }

    it "reports the MemoryStore size" do
      described_class.cache = ActiveSupport::Cache::MemoryStore.new
      described_class.cache.write("key", "value")

      expect(described_class.cache_usage_bytes).to be_positive
    end

    it "reports used_memory for Redis-backed stores, refreshed at most once a minute" do
      store = ActiveSupport::Cache::MemoryStore.new
      stats = { "used_memory" => 1024 }
      store.define_singleton_method(:redis) { :redis }
      store.define_singleton_method(:stats) { stats.dup }
      described_class.cache = store
      described_class.instance_variable_set(:@valkey_cache_stats_last_updated_at, nil)

      expect(described_class.cache_usage_bytes).to eq(1024)
      stats["used_memory"] = 2048
      expect(described_class.cache_usage_bytes).to eq(1024)
    end
    
    it "reports the size of a file store" do
      Dir.mktmpdir do |dir|
        described_class.cache = described_class.file_store(File.join(dir, "cache"), lock_path: File.join(dir, "lock"))
        described_class.instance_variable_set(:@file_cache_stats_last_updated_at, nil)
    
        expect(described_class.cache).to be_a(ActiveSupport::Cache::FileStore)
        expect(described_class.cache_usage_bytes).to be_a(Integer)
      end
    end
  end

  describe ".registry" do
    it "returns a memoized Registry instance" do
      expect(described_class.registry).to be_a(described_class::Registry)
      expect(described_class.registry).to be(described_class.registry)
    end
  end

  describe ".wrap" do
    subject { described_class.wrap(sql, binds) { "yielded_result" } }

    let(:registry) { described_class.registry }
    let(:cache) { described_class.cache }
    let(:sql) { "SELECT * FROM users WHERE id = 1" }
    let(:binds) { [] }

    before do
      cache.clear
      registry.instance_variable_set(:@rules, [])
    end

    context "when binds are present" do
      let(:binds) { ["bind"] }

      before { registry.add_rule(/SELECT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0) }

      it "yields without caching" do
        expect(subject).to eq("yielded_result")
        expect(cache.read(cache_key_for(sql))).to be_nil
      end
    end

    context "when sql is not a SELECT statement" do
      let(:sql) { "INSERT INTO users VALUES (1)" }

      before { registry.add_rule(/INSERT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0) }

      it "yields without caching" do
        expect(subject).to eq("yielded_result")
        expect(cache.instance_variable_get(:@data)).to be_empty
      end
    end

    context "when no rule matches" do
      it "yields without caching" do
        expect(subject).to eq("yielded_result")
        expect(cache.instance_variable_get(:@data)).to be_empty
      end
    end

    context "when a rule matches" do
      context "when the rule has an enabled callable" do
        let(:flag) { { on: false } }

        before do
          state = flag
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0, enabled: -> { state[:on] })
        end

        it "yields without caching while it returns false" do
          expect(subject).to eq("yielded_result")
          expect(cache.read(cache_key_for(sql))).to be_nil
        end

        it "uses the cache normally while it returns true" do
          flag[:on] = true

          expect(subject).to eq("yielded_result")
          expect(described_class.wrap(sql, []) { "different" }).to eq("yielded_result")
        end
      end

      context "when cache is empty" do
        it "yields and caches the result without calling on_cache_hit" do
          called = false
          registry.add_rule(
            /SELECT.*users/,
            name: "user_queries",
            on_cache_hit: proc { |_rule, _result| called = true },
            ttl_seconds: proc { |_result| 60 },
            ttl_jitter_seconds: proc { |_result| 10 }
          )

          expect(described_class.wrap(sql, []) { "yielded_result" }).to eq("yielded_result")
          expect(called).to be(false)

          # Verify cached: second call returns the same result without yielding
          expect(described_class.wrap(sql, []) { "different" }).to eq("yielded_result")
        end
      end

      context "when cache has the result" do
        before { cache.write(cache_key_for(sql), "cached_result") }

        it "emits cache_hit.query_stash, since hits never reach sql.active_record" do
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0)
          events = []
          subscriber = ActiveSupport::Notifications.subscribe("cache_hit.query_stash") do |event|
            events << event.payload
          end

          described_class.wrap(sql, []) { "yielded_result" }

          expect(events).to eq([{ adapter: :active_record, rule: "user_queries" }])
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        it "returns the cached result without yielding and calls on_cache_hit" do
          called_with_result = nil
          registry.add_rule(
            /SELECT.*users/,
            name: "user_queries",
            on_cache_hit: proc { |_rule, result| called_with_result = result },
            ttl_seconds: 60,
            ttl_jitter_seconds: 10
          )

          yielded = false
          result = described_class.wrap(sql, []) do
            yielded = true
            "yielded_result"
          end

          expect(result).to eq("cached_result")
          expect(yielded).to be(false)
          expect(called_with_result).to eq("cached_result")
        end
      end

      context "when TTL is zero or negative" do
        before { registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 0, ttl_jitter_seconds: 0) }

        it "does not cache the result" do
          described_class.wrap(sql, []) { "yielded_result" }

          expect(cache.read(cache_key_for(sql))).to be_nil
        end
      end

      context "when TTL is positive" do
        include ActiveSupport::Testing::TimeHelpers

        before { registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 120, ttl_jitter_seconds: 0) }

        it "caches the result with the TTL" do
          freeze_time do
            described_class.wrap(sql, []) { "yielded_result" }

            expect(described_class.wrap(sql, []) { "different" }).to eq("yielded_result")

            entries = cache.instance_variable_get(:@data)
            expect(entries).to have_key(cache_key_for(sql))
            expect(entries[cache_key_for(sql)].expires_at).to be_between(Time.now.to_f + 120, Time.now.to_f + 121)
          end
        end
      end

      context "when TTL jitter is positive" do
        include ActiveSupport::Testing::TimeHelpers

        before do
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 120, ttl_jitter_seconds: 30)
        end

        it "caches the result with a TTL spread over the jitter window" do
          freeze_time do
            described_class.wrap(sql, []) { "yielded_result" }

            expect(described_class.wrap(sql, []) { "different" }).to eq("yielded_result")
            expires_at = cache.instance_variable_get(:@data)[cache_key_for(sql)].expires_at
            expect(expires_at).to be_between(Time.now.to_f + 120, Time.now.to_f + 150)
          end
        end
      end
    end
  end
end
