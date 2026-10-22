# frozen_string_literal: true

RSpec.describe QueryStash::Railtie do
  describe "config.query_stash defaults" do
    let(:options) { Rails.application.config.query_stash }

    it "hands the stash ActiveSupport's instrumentation and error reporting" do
      expect(options.instrumenter).to be(ActiveSupport::Notifications)
      expect(options.error_reporter).to be(ActiveSupport.error_reporter)
    end
  end

  describe "the options of each adapter" do
    let(:config_options) { Rails.application.config.query_stash }

    it "have a section under config.query_stash for each adapter that is loaded, empty until set" do
      expect(config_options.active_record).to be_empty
      expect(config_options.mongo).to be_empty
      expect(config_options.sequel).to be_empty
    end

    describe ".build" do
      # A config like the app's, with `root` set on config.query_stash and `sections` on the adapters' own.
      def config_with(root = {}, **sections)
        options = ActiveSupport::OrderedOptions.new
                                               .update(config_options.except(:active_record, :mongo))
                                               .update(root)
        sections.each { |name, own| options[name] = ActiveSupport::OrderedOptions.new.update(own) }

        ActiveSupport::OrderedOptions.new.update(query_stash: options)
      end

      def build(adapter, config)
        described_class.build(adapter, config)
      end

      it "inherits what config.query_stash sets, when its section sets nothing" do
        config = config_with({ enabled: false }, active_record: {}, mongo: {})

        expect(build(QueryStash::ActiveRecord, config).enabled).to be(false)
        expect(build(QueryStash::Mongo, config).enabled).to be(false)
      end

      it "takes what its own section sets, over config.query_stash" do
        config = config_with({ enabled: true }, active_record: { enabled: false })

        expect(build(QueryStash::ActiveRecord, config).enabled).to be(false)
      end

      it "leaves the other adapters with config.query_stash" do
        config = config_with({ enabled: true }, active_record: { enabled: false })

        expect(build(QueryStash::Mongo, config).enabled).to be(true)
      end

      it "counts what the section sets to true over a false in config.query_stash" do
        config = config_with({ enabled: false }, mongo: { enabled: true })

        expect(build(QueryStash::Mongo, config).enabled).to be(true)
        expect(build(QueryStash::ActiveRecord, config).enabled).to be(false)
      end

      it "counts a nil in the section as set" do
        config = config_with({ isolated_state: ActiveSupport::IsolatedExecutionState }, mongo: { isolated_state: nil })
        stash = build(QueryStash::Mongo, config)

        # nil is the "none given" of the stash, which keeps its state in a thread variable
        expect(stash.instance_variable_get(:@isolated_state)).to be_a(QueryStash::Base::ThreadVariableState)
      end

      it "takes isolated_state, instrumenter and error_reporter from its section" do
        isolated_state = QueryStash::Base::ThreadVariableState.new
        instrumenter = QueryStash::Base::NullInstrumenter.new
        error_reporter = QueryStash::Base::WarnErrorReporter.new
        config = config_with(
          {},
          active_record: { isolated_state: isolated_state, instrumenter: instrumenter, error_reporter: error_reporter }
        )

        stash = build(QueryStash::ActiveRecord, config)

        expect(stash.instance_variable_get(:@isolated_state)).to be(isolated_state)
        expect(stash.instance_variable_get(:@instrumenter)).to be(instrumenter)
        expect(stash.instance_variable_get(:@error_reporter)).to be(error_reporter)
        other = build(QueryStash::Mongo, config)
        expect(other.instance_variable_get(:@instrumenter)).to be(ActiveSupport::Notifications)
      end

      it "takes cache_store from its section, built like the root's" do
        config = config_with({}, mongo: { cache_store: [:memory_store, { size: 1.megabyte }] })

        mongo = build(QueryStash::Mongo, config)
        expect(mongo.cache.instance_variable_get(:@max_size)).to eq(1.megabyte)
        expect(build(QueryStash::ActiveRecord, config).cache.instance_variable_get(:@max_size)).not_to eq(1.megabyte)
      end

      it "builds the store of cache_store like Rails does, with Rails' own file store for :file_store" do
        Dir.mktmpdir do |dir|
          config = config_with({ cache_store: [:file_store, File.join(dir, "stash")] },
                               mongo: { cache_store: [:file_store, File.join(dir, "other")] })

          expect(build(QueryStash::ActiveRecord, config).cache).to have_attributes(
            class: ActiveSupport::Cache::FileStore, cache_path: File.join(dir, "stash")
          )
          expect(build(QueryStash::Mongo, config).cache.cache_path).to eq(File.join(dir, "other"))
        end
      end

      it "hands back a store instance as it is" do
        store = ActiveSupport::Cache::MemoryStore.new

        expect(build(QueryStash::Mongo, config_with({ cache_store: store })).cache).to be(store)
      end

      it "ignores what a section sets that is not an adapter option" do
        config = config_with({ raise_on_cache_error: true }, active_record: { raise_on_cache_error: false })

        expect(build(QueryStash::ActiveRecord, config).instance_variable_get(:@raise_on_cache_error)).to be(true)
      end

      it "leaves config.query_stash as it was" do
        config = config_with({ enabled: true }, active_record: { enabled: false })

        expect { build(QueryStash::ActiveRecord, config) }.not_to(change { config.query_stash.to_h })
      end
    end
  end

  describe "config.query_stash.isolated_state" do
    it "defaults to ActiveSupport::IsolatedExecutionState" do
      expect(Rails.application.config.query_stash.isolated_state).to be(ActiveSupport::IsolatedExecutionState)
    end

    it "is where the app's stashes keep their value" do
      stash = QueryStash::ActiveRecord[Rails.application]

      stash.enable! { expect(ActiveSupport::IsolatedExecutionState[stash]).to be(true) }
    end
  end

  describe "middleware" do
    let(:request) { Rack::MockRequest.new(Rails.application) }

    it "adds the ActiveRecord, Mongo and Sequel middlewares to the app" do
      expect(Rails.application.middleware).to include(
        QueryStash::ActiveRecord::Middleware, QueryStash::Mongo::Middleware, QueryStash::Sequel::Middleware
      )
    end

    context "with ActiveRecord", database: :active_record do
      before do
        reset_app_stash(QueryStash::ActiveRecord).registry.add_rule(/\ASELECT .*posts/, name: "posts", ttl_seconds: 60,
                                                                                        ttl_jitter_seconds: 0)
      end

      it "serves the next request's lookup from the stash" do
        post = Post.create!(title: "Before")

        expect(request.get("/posts/#{post.id}").body).to eq("Before")
        post.update!(title: "After")

        expect(request.get("/posts/#{post.id}").body).to eq("Before")
      end

      it "stashes requests even while the app's stash is not enabled" do
        allow(QueryStash::ActiveRecord[Rails.application]).to receive(:enabled).and_return(false)
        post = Post.create!(title: "Before")

        expect(request.get("/posts/#{post.id}").body).to eq("Before")
        post.update!(title: "After")

        expect(request.get("/posts/#{post.id}").body).to eq("Before")
      end
    end

    context "with Sequel", database: :active_record do
      before do
        SequelDatabase.db[:sequel_posts].delete
        reset_app_stash(QueryStash::Sequel).registry.add_rule(/\ASELECT .*sequel_posts/, name: "sequel_posts",
                                                                                         ttl_seconds: 60,
                                                                                         ttl_jitter_seconds: 0)
      end

      it "serves the next request's lookup from the stash" do
        id = SequelDatabase.db[:sequel_posts].insert(title: "Before")

        expect(request.get("/sequel_posts/#{id}").body).to eq("Before")
        SequelDatabase.db[:sequel_posts].where(id: id).update(title: "After")

        expect(request.get("/sequel_posts/#{id}").body).to eq("Before")
      end
    end

    context "with Mongo", database: :mongo do
      before do
        reset_app_stash(QueryStash::Mongo).registry.add_rule(
          { collection_name: "mongo_posts" }, name: "mongo_posts", ttl_seconds: 60, ttl_jitter_seconds: 0
        )
      end

      it "serves the next request's lookup from the stash" do
        post = MongoPost.create!(title: "Before")

        expect(request.get("/mongo_posts/#{post.id}").body).to eq("Before")
        post.update!(title: "After")

        expect(request.get("/mongo_posts/#{post.id}").body).to eq("Before")
      end
    end
  end

  describe "ActiveJob" do
    it "enables the stash for both adapters while a job runs and restores it afterwards" do
      expect(StashStateJob.perform_now).to eq([true, true, true])
      expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be_nil
      expect(ActiveSupport::IsolatedExecutionState[QueryStash::Mongo[Rails.application]]).to be_nil
      expect(ActiveSupport::IsolatedExecutionState[QueryStash::Sequel[Rails.application]]).to be_nil
    end

    it "enables the stash for both adapters even while the app's stashes are not enabled" do
      allow(QueryStash::ActiveRecord[Rails.application]).to receive(:enabled).and_return(false)
      allow(QueryStash::Mongo[Rails.application]).to receive(:enabled).and_return(false)
      allow(QueryStash::Sequel[Rails.application]).to receive(:enabled).and_return(false)

      expect(StashStateJob.perform_now).to eq([true, true, true])
    end

    context "with ActiveRecord", database: :active_record do
      before do
        reset_app_stash(QueryStash::ActiveRecord).registry.add_rule(/\ASELECT .*posts/, name: "posts", ttl_seconds: 60,
                                                                                        ttl_jitter_seconds: 0)
      end

      it "serves the next job's lookup from the stash" do
        post = Post.create!(title: "Before")

        expect(PostTitleJob.perform_now(post.id)).to eq("Before")
        post.update!(title: "After")

        expect(PostTitleJob.perform_now(post.id)).to eq("Before")
      end
    end
  end
end
