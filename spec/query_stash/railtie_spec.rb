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
