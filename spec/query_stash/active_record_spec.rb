# frozen_string_literal: true

require "tmpdir"
require "active_support/testing/time_helpers"

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
        registry.add_rule(/UPDATE/, name: "callback_rule", on_cache_hit: callback,
                                    ttl_seconds: 60, ttl_jitter_seconds: 0)
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
        def internal_exec_query(_sql, _name = "SQL", _binds = [], **)
          "original_result"
        end
      end.prepend(described_class).new
    end

    let!(:stash) { reset_app_stash(QueryStash::ActiveRecord) }

    before { stash.registry.add_rule(/SELECT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0) }

    def cached_entries
      stash.cache.instance_variable_get(:@data).length
    end

    context "when neither enable! nor disable! is active" do
      it "runs the query through the app's stash while the app's stash is enabled" do
        adapter.internal_exec_query("SELECT * FROM users")

        expect(cached_entries).to eq(1)
      end

      it "calls super without using the cache while the app's stash is not enabled" do
        allow(stash).to receive(:enabled).and_return(false)

        expect(adapter.internal_exec_query("SELECT * FROM users")).to eq("original_result")
        expect(cached_entries).to eq(0)
      end
    end

    context "when the stash is disabled" do
      it "calls super without using the cache" do
        stash.disable! { adapter.internal_exec_query("SELECT * FROM users") }

        expect(cached_entries).to eq(0)
      end
    end

    context "when the stash is enabled" do
      it "runs the query through the app's stash, even while the app's stash is not enabled" do
        allow(stash).to receive(:enabled).and_return(false)

        stash.enable! { adapter.internal_exec_query("SELECT * FROM users") }

        expect(cached_entries).to eq(1)
      end
    end
  end

  describe ".[] and .set" do
    let(:application) { Object.new }

    after { described_class.instance_variable_get(:@instances).delete(application) }

    it "returns the instance the railtie set for the app" do
      expect(described_class[Rails.application]).to be_a(described_class)
    end

    it "returns the instance set for an application" do
      stash = build_stash(described_class)
      described_class.set(application, stash)

      expect(described_class[application]).to be(stash)
    end

    it "raises for an application nothing was set for" do
      expect { described_class[application] }.to raise_error(KeyError)
    end

    it "keeps its instances apart from Mongo's" do
      described_class.set(application, build_stash(described_class))

      expect { QueryStash::Mongo[application] }.to raise_error(KeyError)
    end
  end

  describe "toggling the stash" do
    describe "#enable!" do
      it "enables the stash" do
        expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be_nil

        QueryStash::ActiveRecord[Rails.application].enable! do
          expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be(true)
        end

        expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be_nil
      end

      it "turns the stash on even while the app's stash is not enabled" do
        allow(QueryStash::ActiveRecord[Rails.application]).to receive(:enabled).and_return(false)

        QueryStash::ActiveRecord[Rails.application].enable! do
          expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be(true)
        end
      end
    end

    describe "#disable!" do
      around do |example|
        QueryStash::ActiveRecord[Rails.application].enable! do
          example.run
        end
      end

      it "disables the stash" do
        expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be(true)

        QueryStash::ActiveRecord[Rails.application].disable! do
          expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be(false)
        end

        expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be(true)
      end
    end
  end

  describe QueryStash::ActiveRecord::Middleware do
    it "enables the stash during the request and restores it afterwards" do
      seen = nil
      app = lambda do |_env|
        seen = ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]
        [200, {}, ["ok"]]
      end

      expect(described_class.new(app, Rails.application).call({})).to eq([200, {}, ["ok"]])
      expect(seen).to be(true)
      expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be_nil
    end

    it "uses the stash of the application it was given" do
      other_application = Object.new
      other_stash = build_stash(QueryStash::ActiveRecord)
      QueryStash::ActiveRecord.set(other_application, other_stash)
      seen = nil
      app = lambda do |_env|
        seen = [ActiveSupport::IsolatedExecutionState[other_stash], ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]]
        [200, {}, ["ok"]]
      end

      described_class.new(app, other_application).call({})

      expect(seen).to eq([true, nil])
    ensure
      QueryStash::ActiveRecord.instance_variable_get(:@instances).delete(other_application)
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

        def internal_exec_query(_sql, _name = "SQL", _binds = [], **)
          @db_call_count += 1
          "db_result"
        end
      end.prepend(QueryStash::ActiveRecord::AdapterPatch).new
    end

    let(:sql) { "SELECT * FROM organizations WHERE organizations.id = 1" }

    before do
      reset_app_stash(described_class).registry.add_rule(/SELECT.*organizations/, name: "test_org_rule",
                                                                                  ttl_seconds: 60,
                                                                                  ttl_jitter_seconds: 0)
    end

    def query_in_parent_then_spawned_thread(&thread_body)
      QueryStash::ActiveRecord[Rails.application].enable! do
        fake_adapter.internal_exec_query(sql)
        fake_adapter.internal_exec_query(sql)
        expect(fake_adapter.db_call_count).to eq(1)

        Thread.new(&thread_body).join
      end
    end

    it "does not carry enable! into spawned threads, which follow the app's enabled instead" do
      allow(described_class[Rails.application]).to receive(:enabled).and_return(false)

      query_in_parent_then_spawned_thread { fake_adapter.internal_exec_query(sql) }

      expect(fake_adapter.db_call_count).to eq(2)
    end

    it "serves a spawned thread from the cache when it enables the stash itself" do
      allow(described_class[Rails.application]).to receive(:enabled).and_return(false)

      query_in_parent_then_spawned_thread do
        QueryStash::ActiveRecord[Rails.application].enable! { fake_adapter.internal_exec_query(sql) }
      end

      expect(fake_adapter.db_call_count).to eq(1)
    end
  end

  describe "#initialize" do
    it "reads enabled from config.query_stash" do
      expect(build_stash(described_class).enabled).to be(true)
      expect(build_stash(described_class, enabled: false).enabled).to be(false)
    end

    it "builds a SqlRegistry" do
      expect(build_stash(described_class).registry).to be_a(described_class::SqlRegistry)
    end
  end

  describe "#cache" do
    it "is a MemoryStore by default" do
      expect(build_stash(described_class).cache).to be_a(ActiveSupport::Cache::MemoryStore)
    end

    it "builds the store config.query_stash.cache_store names, with its options" do
      store = build_stash(described_class, cache_store: [:memory_store, { size: 1.megabyte }]).cache
      expect(store).to be_a(ActiveSupport::Cache::MemoryStore)
      expect(store.instance_variable_get(:@max_size)).to eq(1.megabyte)

      expect(build_stash(described_class, cache_store: :null_store).cache).to be_a(ActiveSupport::Cache::NullStore)
    end
  end

  describe "cache errors" do
    let(:sql) { "SELECT * FROM users WHERE id = 1" }
    let(:failing_store) do
      ActiveSupport::Cache::MemoryStore.new.tap do |store|
        store.define_singleton_method(:read) { |*| raise IOError, "cache is down" }
      end
    end

    def stash_with(**overrides)
      build_stash(described_class, cache_store: failing_store, **overrides).tap do |stash|
        stash.registry.add_rule(/SELECT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0)
      end
    end

    it "raises them in the test environment" do
      expect { stash_with.wrap(sql, []) { "db_result" } }.to raise_error(IOError, "cache is down")
    end

    it "reports them and falls back to the database when raise_on_cache_error is off" do
      allow(ActiveSupport.error_reporter).to receive(:report)

      expect(stash_with(raise_on_cache_error: false).wrap(sql, []) { "db_result" }).to eq("db_result")
      expect(ActiveSupport.error_reporter).to have_received(:report).with(an_instance_of(IOError), handled: true)
    end
  end

  describe "#wrap" do
    subject { stash.wrap(sql, binds) { "yielded_result" } }

    let(:stash) { build_stash(described_class) }
    let(:registry) { stash.registry }
    let(:cache) { stash.cache }
    let(:sql) { "SELECT * FROM users WHERE id = 1" }
    let(:binds) { [] }

    around { |example| stash.enable! { example.run } }

    context "when the stash is not enabled" do
      before { registry.add_rule(/SELECT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0) }

      it "yields without caching" do
        stash.disable! do
          expect(subject).to eq("yielded_result")
        end

        expect(cache.read(cache_key_for(sql))).to be_nil
      end
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
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0,
                                             enabled: -> { state[:on] })
        end

        it "yields without caching while it returns false" do
          expect(subject).to eq("yielded_result")
          expect(cache.read(cache_key_for(sql))).to be_nil
        end

        it "uses the cache normally while it returns true" do
          flag[:on] = true

          expect(subject).to eq("yielded_result")
          expect(stash.wrap(sql, []) { "different" }).to eq("yielded_result")
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

          expect(stash.wrap(sql, []) { "yielded_result" }).to eq("yielded_result")
          expect(called).to be(false)

          # Verify cached: second call returns the same result without yielding
          expect(stash.wrap(sql, []) { "different" }).to eq("yielded_result")
        end
      end

      context "when a result is to be stored" do
        it "emits cache_miss.query_stash right before on_cache_miss" do
          order = []
          registry.add_rule(/SELECT.*users/, name: "user_queries", on_cache_miss: proc { order << :callback },
                                             ttl_seconds: 60, ttl_jitter_seconds: 0)
          ActiveSupport::Notifications.subscribed(->(*, payload) { order << payload }, "cache_miss.query_stash") do
            stash.wrap(sql, []) { "yielded_result" }
          end

          expect(order).to eq([{ adapter: :active_record, rule: "user_queries" }, :callback])
        end

        it "does not emit it for a result that is skipped" do
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 0, ttl_jitter_seconds: 0)

          expect(events_of("cache_miss.query_stash") { stash.wrap(sql, []) { "yielded_result" } }).to be_empty
        end

        it "does not emit it for a hit" do
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0)
          cache.write(cache_key_for(sql), "cached_result")

          expect(events_of("cache_miss.query_stash") { stash.wrap(sql, []) { "yielded_result" } }).to be_empty
        end
      end

      context "when a result is skipped" do
        it "emits cache_skip.query_stash right before on_cache_skip" do
          order = []
          registry.add_rule(/SELECT.*users/, name: "user_queries", on_cache_skip: proc { order << :callback },
                                             ttl_seconds: 0, ttl_jitter_seconds: 0)
          ActiveSupport::Notifications.subscribed(->(*, payload) { order << payload }, "cache_skip.query_stash") do
            stash.wrap(sql, []) { "yielded_result" }
          end

          expect(order).to eq([{ adapter: :active_record, rule: "user_queries" }, :callback])
        end

        it "does not emit it for a result that is stored" do
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0)

          expect(events_of("cache_skip.query_stash") { stash.wrap(sql, []) { "yielded_result" } }).to be_empty
        end

        it "does not emit it for a hit" do
          registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 0, ttl_jitter_seconds: 0)
          cache.write(cache_key_for(sql), "cached_result")

          expect(events_of("cache_skip.query_stash") { stash.wrap(sql, []) { "yielded_result" } }).to be_empty
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

          stash.wrap(sql, []) { "yielded_result" }

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
          result = stash.wrap(sql, []) do
            yielded = true
            "yielded_result"
          end

          expect(result).to eq("cached_result")
          expect(yielded).to be(false)
          expect(called_with_result).to eq("cached_result")
        end
      end

      context "when the cache is read" do
        before { registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 60, ttl_jitter_seconds: 0) }

        def read_events
          events = []
          subscriber = ActiveSupport::Notifications.subscribe("cache_read.query_stash") do |event|
            events << event.payload
          end
          stash.wrap(sql, []) { "yielded_result" }
          events
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        it "instruments the read with the rule name" do
          expect(read_events).to eq([{ adapter: :active_record, rule: "user_queries", hit: false }])
        end

        it "marks the read as a hit when the cache has the result" do
          cache.write(cache_key_for(sql), "cached_result")

          expect(read_events).to eq([{ adapter: :active_record, rule: "user_queries", hit: true }])
        end
      end

      context "when TTL is zero or negative" do
        before { registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 0, ttl_jitter_seconds: 0) }

        it "does not cache the result" do
          stash.wrap(sql, []) { "yielded_result" }

          expect(cache.read(cache_key_for(sql))).to be_nil
        end
      end

      context "when TTL is positive" do
        include ActiveSupport::Testing::TimeHelpers

        before { registry.add_rule(/SELECT.*users/, name: "user_queries", ttl_seconds: 120, ttl_jitter_seconds: 0) }

        it "caches the result with the TTL" do
          freeze_time do
            stash.wrap(sql, []) { "yielded_result" }

            expect(stash.wrap(sql, []) { "different" }).to eq("yielded_result")

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
            stash.wrap(sql, []) { "yielded_result" }

            expect(stash.wrap(sql, []) { "different" }).to eq("yielded_result")
            expires_at = cache.instance_variable_get(:@data)[cache_key_for(sql)].expires_at
            expect(expires_at).to be_between(Time.now.to_f + 120, Time.now.to_f + 150)
          end
        end
      end
    end
  end
end
