# frozen_string_literal: true

require "tmpdir"
require "active_support/testing/time_helpers"

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

  describe QueryStash::Mongo::MongoFilterRegistry do
    let(:registry) { described_class.new }

    describe "#add_rule" do
      it "adds rules with selector, name, and callbacks" do
        registry.add_rule(selector("accounts", { "token" => QueryStash::Mongo::ANY }),
                          name: "test_rule", ttl_seconds: 60, ttl_jitter_seconds: 0)
        expect(registry.rules.length).to eq(1)
        expect(registry.rules.first.name).to eq("test_rule")

        callback = proc { |rule, result| }
        registry.add_rule(selector("users", {}), name: "callback_rule", on_cache_hit: callback,
                                                 ttl_seconds: 60, ttl_jitter_seconds: 0)
        expect(registry.rules[1].on_cache_hit).to eq(callback)

        ttl_proc = proc { 60 }
        registry.add_rule(selector("posts", {}), name: "proc_rule", ttl_seconds: ttl_proc, ttl_jitter_seconds: 0)
        expect(registry.rules.last.ttl_seconds).to eq(ttl_proc)

        expect(registry.rules.length).to eq(3)
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
        registry.add_rule(selector("tags", { "name" => /\Aruby/ }),
                          name: "tags_by_name", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(selector("events", { "meta" => { "kind" => QueryStash::Mongo::ANY } }),
                          name: "events_by_kind", ttl_seconds: 60, ttl_jitter_seconds: 0)
        registry.add_rule(selector("orders", { "ids" => [1] }),
                          name: "orders_by_ids", ttl_seconds: 60, ttl_jitter_seconds: 0)

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
        attr_reader :collection, :database, :filter, :options, :received_block

        define_method(:initialize) do
          @collection = collection
          @database = database
          @filter = { "key" => "value" }
          @options = { limit: nil, skip: nil, sort: nil, projection: nil }
        end

        def respond_to?(method, *)
          method == :pipeline ? false : super
        end

        def each(&block)
          @received_block = block
          yield "original_result" if block
          ["original_result"]
        end
      end.prepend(described_class).new
    end

    let!(:stash) { reset_app_stash(QueryStash::Mongo) }

    before do
      stash.registry.add_rule(
        selector("test_collection", { "key" => QueryStash::Mongo::ANY }),
        name: "test",
        ttl_seconds: 60,
        ttl_jitter_seconds: 10
      )
    end

    context "when the stash is enabled" do
      around do |example|
        QueryStash::Mongo[Rails.application].enable! { example.run }
      end

      it "uses the cache for matching queries" do
        view.each

        expect(stash.cache.instance_variable_get(:@data).length).to eq(1)
      end

      context "when no rule matches" do
        before { stash.registry.instance_variable_set(:@rules, []) }

        it "streams the cursor through without buffering or caching it" do
          docs = []
          caller_block = proc { |doc| docs << doc }
          view.each(&caller_block)

          expect(view.received_block).to be(caller_block)
          expect(docs).to eq(["original_result"])
          expect(stash.cache.instance_variable_get(:@data)).to be_empty
        end
      end
    end

    context "when the stash is disabled" do
      it "does not use the cache" do
        stash.disable! { view.each }

        expect(stash.cache.instance_variable_get(:@data).length).to eq(0)
      end
    end

    context "when neither enable! nor disable! is active" do
      it "follows the app's enabled" do
        view.each
        expect(stash.cache.instance_variable_get(:@data).length).to eq(1)

        stash.cache.clear
        allow(stash).to receive(:enabled).and_return(false)
        view.each
        expect(stash.cache.instance_variable_get(:@data).length).to eq(0)
      end
    end
  end

  describe "toggling the stash" do
    describe "#enable!" do
      it "enables the stash" do
        expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be_nil

        QueryStash::Mongo[Rails.application].enable! do
          expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be(true)
        end

        expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be_nil
      end

      it "turns the stash on even while the app's stash is not enabled" do
        allow(QueryStash::Mongo[Rails.application]).to receive(:enabled).and_return(false)

        QueryStash::Mongo[Rails.application].enable! do
          expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be(true)
        end
      end
    end

    describe "#disable!" do
      around do |example|
        QueryStash::Mongo[Rails.application].enable! do
          example.run
        end
      end

      it "disables the stash" do
        expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be(true)

        QueryStash::Mongo[Rails.application].disable! do
          expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be(false)
        end

        expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be(true)
      end
    end
  end

  describe QueryStash::Mongo::Middleware do
    it "enables the stash during the request and restores it afterwards" do
      seen = nil
      app = lambda do |_env|
        seen = QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]
        [200, {}, ["ok"]]
      end

      expect(described_class.new(app, Rails.application).call({})).to eq([200, {}, ["ok"]])
      expect(seen).to be(true)
      expect(QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]).to be_nil
    end

    it "uses the stash of the application it was given" do
      other_application = Object.new
      other_stash = build_stash(QueryStash::Mongo)
      QueryStash::Mongo.set(other_application, other_stash)
      seen = nil
      app = lambda do |_env|
        seen = [QueryStash::IsolatedState[other_stash], QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]]
        [200, {}, ["ok"]]
      end

      described_class.new(app, other_application).call({})

      expect(seen).to eq([true, nil])
    ensure
      QueryStash::Mongo.instance_variable_get(:@instances).delete(other_application)
    end
  end

  describe "#cache" do
    it "is a MemoryStore by default" do
      expect(build_stash(described_class).cache).to be_a(ActiveSupport::Cache::MemoryStore)
    end

    it "builds a QueryStash::FileStore under a mongo- prefixed path for :file_store" do
      Dir.mktmpdir do |dir|
        store = build_stash(described_class, cache_store: [:file_store, File.join(dir, "stash")]).cache

        expect(store).to be_a(QueryStash::FileStore)
        expect(store.cache_path).to eq(File.join(dir, "mongo-stash"))
      end
    end
  end

  describe "#initialize" do
    it "builds a MongoFilterRegistry" do
      expect(build_stash(described_class).registry).to be_a(described_class::MongoFilterRegistry)
    end
  end

  describe "#cache_usage_bytes" do
    def redis_like_store(used)
      ActiveSupport::Cache::MemoryStore.new.tap do |store|
        store.define_singleton_method(:redis) { :redis }
        store.define_singleton_method(:stats) { { "used_memory" => used } }
      end
    end

    it "reports the MemoryStore size" do
      stash = build_stash(described_class)
      stash.cache.write("key", "value")

      expect(stash.cache_usage_bytes).to be_positive
    end

    it "tracks the once-a-minute Redis stats per store" do
      stash = build_stash(described_class, cache_store: redis_like_store(1024))
      routed = described_class::Registry::Rule.new(
        selector: {}, name: "routed", ttl_seconds: 60, ttl_jitter_seconds: 0,
        on_cache_hit: nil, on_cache_miss: nil, on_cache_skip: nil, enabled: nil, store: redis_like_store(4096)
      )

      expect(stash.cache_usage_bytes).to eq(1024)
      expect(stash.cache_usage_bytes(routed)).to eq(4096)
    end

    it "reports the size of a file store" do
      Dir.mktmpdir do |dir|
        stash = build_stash(described_class, cache_store: [:file_store, File.join(dir, "cache")])

        expect(stash.cache_usage_bytes).to be_a(Integer)
      end
    end
  end

  describe "#wrap" do
    let(:stash) { build_stash(described_class) }
    let(:registry) { stash.registry }
    let(:cache) { stash.cache }
    let(:cursor_runs) { [] }
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

    around { |example| stash.enable! { example.run } }

    before { allow(view).to receive(:respond_to?).with(:pipeline).and_return(false) }

    # Stands in for the driver's cursor: records each run, then yields `docs` to the block it gets.
    def documents(docs = ["db_doc"], consumer: nil)
      stash.wrap(view, consumer) do |&iterate|
        cursor_runs << iterate
        docs.each(&iterate)
      end.to_a
    end

    context "when the stash is not enabled" do
      before { registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 60, ttl_jitter_seconds: 0) }

      it "runs the cursor without caching" do
        stash.disable! do
          expect(documents).to eq(["db_doc"])
        end

        expect(cache.read(cache_key_for(view))).to be_nil
      end
    end

    context "when no rule matches" do
      it "streams the cursor straight into the consumer, without caching" do
        consumer = proc { |_doc| }

        documents(consumer: consumer)

        expect(cursor_runs).to eq([consumer])
        expect(cache.instance_variable_get(:@data)).to be_empty
      end
    end

    context "when a rule matches" do
      context "when cache is empty" do
        it "loads the documents and caches them without calling on_cache_hit" do
          called = false
          registry.add_rule(
            rule_selector,
            name: "accounts_by_token",
            on_cache_hit: proc { |_rule, _result| called = true },
            ttl_seconds: proc { |_result| 60 },
            ttl_jitter_seconds: proc { |_result| 10 }
          )

          expect(documents).to eq(["db_doc"])
          expect(called).to be(false)
          expect(documents(["different"])).to eq(["db_doc"])
          expect(cursor_runs.length).to eq(1)
        end

        it "hands the documents to the consumer" do
          registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 60, ttl_jitter_seconds: 0)
          received = []

          documents(%w[a b], consumer: proc { |doc| received << doc })

          expect(received).to eq(%w[a b])
        end
      end

      context "when cache has the result" do
        before { cache.write(cache_key_for(view), ["cached_doc"]) }

        it "returns the cached documents without running the cursor and calls on_cache_hit" do
          called_with_result = nil
          registry.add_rule(
            rule_selector,
            name: "accounts_by_token",
            on_cache_hit: proc { |_rule, result| called_with_result = result },
            ttl_seconds: 60,
            ttl_jitter_seconds: 10
          )

          expect(documents).to eq(["cached_doc"])
          expect(cursor_runs).to be_empty
          expect(called_with_result).to eq(["cached_doc"])
        end
      end

      context "when the cache is read" do
        before { registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 60, ttl_jitter_seconds: 0) }

        def read_events
          events = []
          subscriber = ActiveSupport::Notifications.subscribe("cache_read.query_stash") do |event|
            events << event.payload
          end
          documents
          events
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        it "instruments the read with the rule name" do
          expect(read_events).to eq([{ adapter: :mongo, rule: "accounts_by_token", hit: false }])
        end

        it "marks the read as a hit when the cache has the result" do
          cache.write(cache_key_for(view), ["cached_doc"])

          expect(read_events).to eq([{ adapter: :mongo, rule: "accounts_by_token", hit: true }])
        end
      end

      context "when the rule is routed to its own store" do
        let(:routed_store) { ActiveSupport::Cache::MemoryStore.new }

        before do
          registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 60, ttl_jitter_seconds: 0,
                                           store: routed_store)
        end

        it "reads and writes that store and leaves the default one alone" do
          expect(documents).to eq(["db_doc"])

          expect(routed_store.read(cache_key_for(view))).to eq(["db_doc"])
          expect(cache.instance_variable_get(:@data)).to be_empty
          expect(documents(["different"])).to eq(["db_doc"])
        end

        it "measures the rule's store in cache_usage_bytes" do
          documents
          rule = registry.match_rule(selector("accounts", { "token" => "acct_abc123" }))

          expect(stash.cache_usage_bytes(rule)).to be_positive
          expect(stash.cache_usage_bytes).to eq(0)
        end
      end

      context "when TTL is zero or negative" do
        before { registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 0, ttl_jitter_seconds: 0) }

        it "does not cache the result" do
          documents

          expect(cache.read(cache_key_for(view))).to be_nil
        end
      end

      context "when TTL is positive" do
        include ActiveSupport::Testing::TimeHelpers

        before { registry.add_rule(rule_selector, name: "accounts_by_token", ttl_seconds: 120, ttl_jitter_seconds: 0) }

        it "caches the result with the TTL" do
          freeze_time do
            documents

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
            documents

            expires_at = cache.instance_variable_get(:@data)[cache_key_for(view)].expires_at
            expect(expires_at).to be_between(Time.now.to_f + 120, Time.now.to_f + 150)
          end
        end
      end
    end
  end
end
