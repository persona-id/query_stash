# frozen_string_literal: true

RSpec.describe QueryStash::Rack::Middleware do
  describe "#call" do
    it "enables the stash for both adapters during the request and restores it afterwards" do
      seen = nil
      app = lambda do |_env|
        seen = [
          QueryStash.state[:query_stash_active_record_enabled],
          QueryStash.state[:query_stash_mongo_enabled]
        ]
        [200, {}, ["ok"]]
      end

      response = described_class.new(app).call({})

      expect(response).to eq([200, {}, ["ok"]])
      expect(seen).to eq([true, true])
      expect(QueryStash.state[:query_stash_active_record_enabled]).to be_nil
      expect(QueryStash.state[:query_stash_mongo_enabled]).to be_nil
    end
  end

  describe "in the dummy app's middleware stack" do
    let(:request) { Rack::MockRequest.new(Rails.application) }

    it "is installed" do
      expect(Rails.application.middleware).to include(described_class)
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
end
