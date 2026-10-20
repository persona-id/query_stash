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
    QueryStash::ActiveRecord.cache.clear
    QueryStash::ActiveRecord.registry.instance_variable_set(:@rules, [])
    QueryStash::ActiveRecord.registry.add_rule(
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
    expect(Post.connection.class.ancestors).to include(QueryStash::ActiveRecord::AdapterPatch)
  end

  it "serves repeated lookups of a published row from the stash" do
    post = Post.create!(status: "published", title: "Hello")

    ActiveRecord::Base.with_query_stash do
      expect(Post.find(post.id).title).to eq("Hello")
      expect(Post.find(post.id).title).to eq("Hello")
    end

    expect(lookups(post.id)).to eq(1)
    expect(hits).to eq([{ adapter: :active_record, rule: "post_by_id" }])
  end

  it "does not cache rows the TTL callable skips" do
    post = Post.create!(status: "draft", title: "WIP")

    ActiveRecord::Base.with_query_stash do
      2.times { Post.find(post.id) }
    end

    expect(lookups(post.id)).to eq(2)
  end

  it "keeps serving the cached row after a write until the TTL expires" do
    post = Post.create!(status: "published", title: "Before")

    ActiveRecord::Base.with_query_stash do
      Post.find(post.id)
      Post.where(id: post.id).update_all(title: "After")

      expect(Post.find(post.id).title).to eq("Before")
    end

    expect(Post.find(post.id).title).to eq("After")
  end

  it "leaves queries alone outside a with_query_stash block" do
    post = Post.create!(status: "published", title: "Hello")

    2.times { Post.find(post.id) }

    expect(lookups(post.id)).to eq(2)
    expect(hits).to be_empty
  end
end
