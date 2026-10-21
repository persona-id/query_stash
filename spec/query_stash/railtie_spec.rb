# frozen_string_literal: true

RSpec.describe QueryStash::Railtie do
  describe "config.query_stash defaults" do
    let(:options) { Rails.application.config.query_stash }

    it "hands the stash ActiveSupport's instrumentation and error reporting" do
      expect(options.instrumenter).to be(ActiveSupport::Notifications)
      expect(options.error_reporter).to be(ActiveSupport.error_reporter)
    end
  end

  describe ".build_cache_store" do
    it "resolves a store name and its options like Rails does" do
      store = described_class.build_cache_store(QueryStash::ActiveRecord, :memory_store, { size: 1.megabyte })

      expect(store).to be_a(ActiveSupport::Cache::MemoryStore)
      expect(store.instance_variable_get(:@max_size)).to eq(1.megabyte)
    end

    it "hands back a store instance as it is" do
      store = ActiveSupport::Cache::MemoryStore.new

      expect(described_class.build_cache_store(QueryStash::Mongo, store)).to be(store)
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

    it "adds the ActiveRecord and Mongo middlewares to the app" do
      expect(Rails.application.middleware).to include(QueryStash::ActiveRecord::Middleware, QueryStash::Mongo::Middleware)
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
      expect(StashStateJob.perform_now).to eq([true, true])
      expect(ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]]).to be_nil
      expect(ActiveSupport::IsolatedExecutionState[QueryStash::Mongo[Rails.application]]).to be_nil
    end

    it "enables the stash for both adapters even while the app's stashes are not enabled" do
      allow(QueryStash::ActiveRecord[Rails.application]).to receive(:enabled).and_return(false)
      allow(QueryStash::Mongo[Rails.application]).to receive(:enabled).and_return(false)

      expect(StashStateJob.perform_now).to eq([true, true])
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
