# frozen_string_literal: true

RSpec.describe QueryStash::Railtie do
  describe "middleware" do
    let(:request) { Rack::MockRequest.new(Rails.application) }

    it "adds the ActiveRecord and Mongo middlewares to the app" do
      expect(Rails.application.middleware).to include(QueryStash::ActiveRecord::Middleware, QueryStash::Mongo::Middleware)
    end

    context "with ActiveRecord", database: :active_record do
      before do
        QueryStash::ActiveRecord.cache.clear
        QueryStash::ActiveRecord.registry.instance_variable_set(:@rules, [])
        QueryStash::ActiveRecord.registry.add_rule(/\ASELECT .*posts/, name: "posts", ttl_seconds: 60,
                                                                       ttl_jitter_seconds: 0)
      end

      it "serves the next request's lookup from the stash" do
        post = Post.create!(title: "Before")

        expect(request.get("/posts/#{post.id}").body).to eq("Before")
        post.update!(title: "After")

        expect(request.get("/posts/#{post.id}").body).to eq("Before")
      end

      it "does not stash while config.query_stash.enabled is false" do
        Rails.application.config.query_stash.enabled = false
        post = Post.create!(title: "Before")

        expect(request.get("/posts/#{post.id}").body).to eq("Before")
        post.update!(title: "After")

        expect(request.get("/posts/#{post.id}").body).to eq("After")
      ensure
        Rails.application.config.query_stash.enabled = true
      end
    end

    context "with Mongo", database: :mongo do
      before do
        QueryStash::Mongo.cache.clear
        QueryStash::Mongo.registry.instance_variable_set(:@rules, [])
        QueryStash::Mongo.registry.add_rule({ collection_name: "mongo_posts" }, name: "mongo_posts", ttl_seconds: 60,
                                                                                ttl_jitter_seconds: 0)
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
      expect(QueryStash::IsolatedState[:query_stash_active_record_enabled]).to be_nil
      expect(QueryStash::IsolatedState[:query_stash_mongo_enabled]).to be_nil
    end

    it "leaves the stash off while config.query_stash.enabled is false" do
      Rails.application.config.query_stash.enabled = false

      expect(StashStateJob.perform_now).to eq([false, false])
    ensure
      Rails.application.config.query_stash.enabled = true
    end

    context "with ActiveRecord", database: :active_record do
      before do
        QueryStash::ActiveRecord.cache.clear
        QueryStash::ActiveRecord.registry.instance_variable_set(:@rules, [])
        QueryStash::ActiveRecord.registry.add_rule(/\ASELECT .*posts/, name: "posts", ttl_seconds: 60,
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
