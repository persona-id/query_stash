# frozen_string_literal: true

RSpec.describe "QueryStash::ActiveRecord against the dummy app's database", database: :active_record do
  let(:queries) { [] }
  let(:hits) { [] }

  # Quoting differs per engine ("posts" vs `posts`), so build the prefix the adapter actually sends.
  let(:lookup_prefix) do
    connection = Post.connection
    posts = connection.quote_table_name("posts")

    "SELECT #{posts}.* FROM #{posts} WHERE #{posts}.#{connection.quote_column_name("id")} = "
  end

  before do
    Post.delete_all
    reset_app_stash(QueryStash::ActiveRecord).registry.add_rule(
      /\A#{Regexp.escape(lookup_prefix)}\d+/,
      name: "post_by_id",
      ttl_seconds: ->(result) { result.to_a.all? { |row| row["status"] == "published" } ? 60 : 0 },
      ttl_jitter_seconds: 0
    )
  end

  around do |example|
    sql = ActiveSupport::Notifications.subscribe("sql.active_record") { |event| queries << event.payload[:sql] }
    hit = ActiveSupport::Notifications.subscribe("cache_hit.query_stash") { |event| hits << event.payload }
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(sql)
    ActiveSupport::Notifications.unsubscribe(hit)
  end

  def lookups(id)
    queries.count { |sql| sql.start_with?("#{lookup_prefix}#{id}") }
  end

  it "patches the adapter the app connects with" do
    patch = Post.connection.class.method_defined?(:execute_intent) ? :IntentAdapterPatch : :AdapterPatch

    expect(Post.connection.class.ancestors).to include(QueryStash::ActiveRecord.const_get(patch))
  end

  it "serves repeated lookups of a published row from the stash" do
    post = Post.create!(status: "published", title: "Hello")

    QueryStash::ActiveRecord[Rails.application].enable! do
      expect(Post.find(post.id).title).to eq("Hello")
      expect(Post.find(post.id).title).to eq("Hello")
    end

    expect(lookups(post.id)).to eq(1)
    expect(hits).to eq([{ adapter: :active_record, rule: "post_by_id" }])
  end

  it "stores a row once, and does not refresh it when it is served from the stash" do
    post = Post.create!(status: "published", title: "Hello")
    stash = QueryStash::ActiveRecord[Rails.application]
    allow(stash.cache).to receive(:write).and_call_original

    stash.enable! { 3.times { Post.find(post.id) } }

    expect(stash.cache).to have_received(:write).once
  end

  it "does not cache rows the TTL callable skips" do
    post = Post.create!(status: "draft", title: "WIP")

    QueryStash::ActiveRecord[Rails.application].enable! do
      2.times { Post.find(post.id) }
    end

    expect(lookups(post.id)).to eq(2)
  end

  it "keeps serving the cached row after a write until the TTL expires" do
    post = Post.create!(status: "published", title: "Before")

    QueryStash::ActiveRecord[Rails.application].enable! do
      Post.find(post.id)
      Post.where(id: post.id).update_all(title: "After")

      expect(Post.find(post.id).title).to eq("Before")
    end

    QueryStash::ActiveRecord[Rails.application].disable! do
      expect(Post.find(post.id).title).to eq("After")
    end
  end

  it "follows config.query_stash.enabled outside enable! and disable!" do
    post = Post.create!(status: "published", title: "Hello")

    2.times { Post.find(post.id) }
    expect(lookups(post.id)).to eq(1)

    allow(QueryStash::ActiveRecord[Rails.application]).to receive(:enabled).and_return(false)
    2.times { Post.find(post.id) }
    expect(lookups(post.id)).to eq(3)
  end

  it "leaves queries alone inside disable!" do
    post = Post.create!(status: "published", title: "Hello")

    QueryStash::ActiveRecord[Rails.application].disable! { 2.times { Post.find(post.id) } }

    expect(lookups(post.id)).to eq(2)
    expect(hits).to be_empty
  end
end
