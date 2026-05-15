# frozen_string_literal: true

require "active_support/testing/time_helpers"
require "query_stash/mongo"

RSpec.describe QueryStash::Mongo do
  def selector(collection_name, filter)
    {
      collection_name: collection_name,
      filter: filter,
      limit: nil,
      skip: nil,
      sort: nil,
      projection: nil,
      pipeline: nil
    }
  end

  def cache_key_for(view)
    raw = [
      view.collection.name,
      view.filter,
      view.options[:limit],
      view.options[:skip],
      view.options[:sort],
      view.options[:projection],
      nil
    ].to_json

    "v1:#{view.database.name}:#{Digest::SHA256.hexdigest(raw)}"
  end

  describe QueryStash::Mongo::Registry do
    let(:registry) { described_class.new }

    describe "#add_rule" do
      it "adds rules with selector, name, callbacks, and validates required fields" do
        registry.add_rule(selector("accounts", { "token" => QueryStash::Mongo::ANY }), name: "test_rule", ttl_seconds: 60, ttl_jitter_seconds: 0)
        expect(registry.rules.length).to eq(1)
        expect(registry.rules.first.name).to eq("test_rule")

        callback = proc { |rule, result| }
        registry.add_rule(selector("users", {}), name: "callback_rule", on_cache_hit: callback, ttl_seconds: 60, ttl_jitter_seconds: 0)
        expect(registry.rules[1].on_cache_hit).to eq(callback)

        ttl_proc = proc { 60 }
        registry.add_rule(selector("posts", {}), name: "proc_rule", ttl_seconds: ttl_proc, ttl_jitter_seconds: 0)
        expect(registry.rules.last.ttl_seconds).to eq(ttl_proc)

        expect(registry.rules.length).to eq(3)

        expect do
          registry.add_rule({ collection_name: "users" }, name: "partial_rule", ttl_seconds: 60, ttl_jitter_seconds: 0)
        end.to raise_error("Rule selector must contain :filter")
      end
    end

    describe "#delete_rule" do
      it "deletes rules by name and ignores unknown names" do
        registry.add_rule(selector("accounts", {}), name: "test_rule", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(selector("users", {}), name: "other_rule", ttl_seconds: 120, ttl_jitter_seconds: 0)

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
        registry.add_rule(selector("accounts", { "token" => QueryStash::Mongo::ANY }),
                          name: "accounts_by_token", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(selector("users", { "email" => QueryStash::Mongo::ANY }),
                          name: "users_by_email", ttl_seconds: 120, ttl_jitter_seconds: 0)
      end

      it "returns the first matching rule, or nil" do
        expect(registry.match_rule(selector("accounts", { "token" => "acct_abc123" })).name).to eq("accounts_by_token")
        expect(registry.match_rule(selector("posts", {}))).to be_nil

        registry.add_rule(selector("accounts", {}), name: "generic_accounts", ttl_seconds: 30, ttl_jitter_seconds: 0)
        expect(registry.match_rule(selector("accounts", { "token" => "acct_xyz789" })).name).to eq("accounts_by_token")
      end

      it "supports Proc, Regexp, nested Hash and prefix Array patterns" do
        registry.add_rule(
          selector("posts", { "status" => ->(value) { %w[draft published].include?(value) } }),
          name: "posts_by_status", ttl_seconds: 60, ttl_jitter_seconds: 0
        )
        registry.add_rule(selector("tags", { "name" => /\Aruby/ }), name: "tags_by_name", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(selector("events", { "meta" => { "kind" => QueryStash::Mongo::ANY } }),
                          name: "events_by_kind", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(selector("orders", { "ids" => [1] }), name: "orders_by_ids", ttl_seconds: 60, ttl_jitter_seconds: 0)

        expect(registry.match_rule(selector("posts", { "status" => "published" })).name).to eq("posts_by_status")
        expect(registry.match_rule(selector("posts", { "status" => "archived" }))).to be_nil
        expect(registry.match_rule(selector("tags", { "name" => "rubygems" })).name).to eq("tags_by_name")
        expect(registry.match_rule(selector("events", { "meta" => { "kind" => "x", "at" => 1 } })).name)
          .to eq("events_by_kind")
        expect(registry.match_rule(selector("orders", { "ids" => [1, 2] })).name).to eq("orders_by_ids")
        expect(registry.match_rule(selector("orders", { "ids" => [2, 1] }))).to be_nil
      end
    end
  end

  describe QueryStash::Mongo::AdapterPatch do
    let(:view) do
      collection = instance_double(Mongo::Collection, name: "test_collection")
      database = instance_double(Mongo::Database, name: "test_db")
      Class.new do
        attr_reader :collection, :database, :filter, :options

        define_method(:initialize) do
          @collection = collection
          @database = database
          @filter = { "key" => "value" }
          @options = { limit: nil, skip: nil, sort: nil, projection: nil }
        end

        def respond_to?(method, include_all = false)
          method == :pipeline ? false : super
        end

        def each
          yield "original_result" if block_given?
          ["original_result"]
        end
      end.prepend(described_class).new
    end

    before do
      QueryStash::Mongo.registry.instance_variable_set(:@rules, [])
      QueryStash::Mongo.cache.clear
      QueryStash::Mongo.registry.add_rule(
        selector("test_collection", { "key" => QueryStash::Mongo::ANY }),
        name: "test",
        ttl_seconds: 60,
        ttl_jitter_seconds: 10
      )
    end

    after do
      Thread.current[:query_stash_mongo_enabled] = false
    end

    context "when the stash is enabled" do
      before do
        Thread.current[:query_stash_mongo_enabled] = true
      end

      it "uses the cache for matching queries" do
        view.each

        expect(QueryStash::Mongo.cache.instance_variable_get(:@data).length).to eq(1)
      end
    end

    context "when the stash is not enabled" do
      before do
        Thread.current[:query_stash_mongo_enabled] = false
      end

      it "does not use the cache" do
        view.each

        expect(QueryStash::Mongo.cache.instance_variable_get(:@data).length).to eq(0)
      end
    end
  end

  describe QueryStash::Mongo::BasePatch do
    describe "#with_query_stash" do
      before do
        # Ensure clean state before test to avoid pollution from other tests
        Thread.current[:query_stash_mongo_enabled] = nil
      end

      it "enables the stash" do
        expect(Thread.current[:query_stash_mongo_enabled]).to be_nil

        Mongo.with_query_stash do
          expect(Thread.current[:query_stash_mongo_enabled]).to be(true)
        end

        expect(Thread.current[:query_stash_mongo_enabled]).to be_nil
      end
    end

    describe "#without_query_stash" do
      around do |example|
        Mongo.with_query_stash do
          example.run
        end
      end

      it "disables the stash" do
        expect(Thread.current[:query_stash_mongo_enabled]).to be(true)

        Mongo.without_query_stash do
          expect(Thread.current[:query_stash_mongo_enabled]).to be(false)
        end

        expect(Thread.current[:query_stash_mongo_enabled]).to be(true)
      end
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
      described_class.instance_variable_set(:@_cache_stats_last_updated_at, nil)

      expect(described_class.cache_usage_bytes).to eq(1024)
      stats["used_memory"] = 2048
      expect(described_class.cache_usage_bytes).to eq(1024)
    end
  end

  describe ".registry" do
    it "returns a memoized Registry instance" do
      expect(described_class.registry).to be_a(described_class::Registry)
      expect(described_class.registry).to be(described_class.registry)
    end
  end

  describe ".wrap" do
    subject { described_class.wrap(view) { "yielded_result" } }

    let(:registry) { described_class.registry }
    let(:cache) { described_class.cache }
    let(:view) do
      instance_double(
        Mongo::Collection::View,
        collection: instance_double(Mongo::Collection, name: "accounts"),
        database: instance_double(Mongo::Database, name: "test_db"),
        filter: { "token" => "acct_abc123" },
        options: { limit: nil, skip: nil, sort: nil, projection: nil }
      )
    end
    let(:rule_selector) { selector("accounts", { "token" => QueryStash::Mongo::ANY }) }

    before do
      cache.clear
      registry.instance_variable_set(:@rules, [])
      allow(view).to receive(:respond_to?).with(:pipeline).and_return(false)
    end

    context "when no rule matches" do
      it "yields without caching" do
        expect(subject).to eq("yielded_result")
        expect(cache.instance_variable_get(:@data)).to be_empty
      end
    end

    context "when a rule matches" do
      context "when cache is empty" do
        it "yields and caches the result without calling on_cache_hit" do
          called = false
          registry.add_rule(
            rule_selector,
            name: "accounts_by_token",
            on_cache_hit: proc { |_rule, _result| called = true },
            ttl_seconds: proc { |_result| 60 },
            ttl_jitter_seconds: proc { |_result| 10 }
          )

          expect(described_class.wrap(view) { "yielded_result" }).to eq("yielded_result")
          expect(called).to be(false)

          # Verify cached: second call returns the same result without yielding
          expect(described_class.wrap(view) { "different" }).to eq("yielded_result")
        end
      end

      context "when cache has the result" do
        before { cache.write(cache_key_for(view), described_class.send(:encode, "cached_result")) }

        it "returns the cached result without yielding and calls on_cache_hit" do
          called_with_result = nil
          registry.add_rule(
            rule_selector,
            name: "accounts_by_token",
            on_cache_hit: proc { |_rule, result| called_with_result = result },
            ttl_seconds: 60,
            ttl_jitter_seconds: 10
          )

          yielded = false
          result = described_class.wrap(view) do
            yielded = true
            "yielded_result"
          end

          expect(result).to eq("cached_result")
          expect(yielded).to be(false)
          expect(called_with_result).to eq("cached_result")
        end
      end

      context "when TTL is zero or negative" do
        before { registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 0, ttl_jitter_seconds: 0) }

        it "does not cache the result" do
          described_class.wrap(view) { "yielded_result" }

          expect(cache.read(cache_key_for(view))).to be_nil
        end
      end

      context "when TTL is positive" do
        include ActiveSupport::Testing::TimeHelpers

        before { registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 120, ttl_jitter_seconds: 0) }

        it "caches the result with the TTL" do
          freeze_time do
            described_class.wrap(view) { "yielded_result" }

            expect(described_class.wrap(view) { "different" }).to eq("yielded_result")

            entries = cache.instance_variable_get(:@data)
            expect(entries).to have_key(cache_key_for(view))
            expect(entries[cache_key_for(view)].expires_at).to be_between(Time.now.to_f + 120, Time.now.to_f + 121)
          end
        end
      end

      context "when TTL jitter is positive" do
        include ActiveSupport::Testing::TimeHelpers

        before { registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 120, ttl_jitter_seconds: 30) }

        it "caches the result with a TTL spread over the jitter window" do
          freeze_time do
            described_class.wrap(view) { "yielded_result" }

            expect(described_class.wrap(view) { "different" }).to eq("yielded_result")
            expires_at = cache.instance_variable_get(:@data)[cache_key_for(view)].expires_at
            expect(expires_at).to be_between(Time.now.to_f + 120, Time.now.to_f + 150)
          end
        end
      end
    end
  end
end
