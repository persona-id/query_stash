# frozen_string_literal: true

RSpec.describe "QueryStash::Mongo against the dummy app's database", database: :mongo do
  let(:finds) { [] }

  let(:find_counter) do
    commands = finds
    Class.new do
      define_method(:started) do |event|
        commands << event.command["filter"] if event.command_name == "find"
      end

      def succeeded(_event); end

      def failed(_event); end
    end.new
  end

  before do
    MongoPost.delete_all
    reset_app_stash(QueryStash::Mongo).registry.add_rule(
      { collection_name: "mongo_posts", filter: { "_id" => QueryStash::Mongo::ANY } },
      name: "mongo_post_by_id",
      ttl_seconds: ->(docs) { docs.all? { |doc| doc["status"] == "published" } ? 60 : 0 },
      ttl_jitter_seconds: 0
    )
  end

  around do |example|
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, find_counter)
    example.run
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, find_counter)
  end

  def lookups(id)
    finds.count { |filter| filter == { "_id" => id } }
  end

  it "serves repeated lookups of a published document from the stash" do
    post = MongoPost.create!(status: "published", title: "Hello")

    QueryStash::Mongo[Rails.application].enable! do
      expect(MongoPost.find(post.id).title).to eq("Hello")
      expect(MongoPost.find(post.id).title).to eq("Hello")
    end

    expect(lookups(post.id)).to eq(1)
  end

  it "does not cache documents the TTL callable skips" do
    post = MongoPost.create!(status: "draft", title: "WIP")

    QueryStash::Mongo[Rails.application].enable! do
      2.times { MongoPost.find(post.id) }
    end

    expect(lookups(post.id)).to eq(2)
  end

  it "keeps serving the cached document after a write until the TTL expires" do
    post = MongoPost.create!(status: "published", title: "Before")

    QueryStash::Mongo[Rails.application].enable! do
      MongoPost.find(post.id)
      MongoPost.where(_id: post.id).update_all(title: "After")

      expect(MongoPost.find(post.id).title).to eq("Before")
    end

    QueryStash::Mongo[Rails.application].disable! do
      expect(MongoPost.find(post.id).title).to eq("After")
    end
  end

  it "follows config.query_stash.enabled outside enable! and disable!" do
    post = MongoPost.create!(status: "published", title: "Hello")

    2.times { MongoPost.find(post.id) }
    expect(lookups(post.id)).to eq(1)

    allow(QueryStash::Mongo[Rails.application]).to receive(:enabled).and_return(false)
    2.times { MongoPost.find(post.id) }
    expect(lookups(post.id)).to eq(3)
  end

  it "leaves queries alone inside disable!" do
    post = MongoPost.create!(status: "published", title: "Hello")

    QueryStash::Mongo[Rails.application].disable! { 2.times { MongoPost.find(post.id) } }

    expect(lookups(post.id)).to eq(2)
  end
end
