# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters/sqlite3_adapter"
require "query_stash/active_record"

RSpec.describe "QueryStash::ActiveRecord against SQLite" do
  let(:post_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "posts"

      def self.name = "Post"
    end
  end

  let(:queries) { [] }
  let(:hits) { [] }

  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:", prepared_statements: false)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:posts) do |t|
        t.string :status
        t.string :title
      end
    end
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
  end

  before do
    post_class.delete_all
    QueryStash::ActiveRecord.cache.clear
    QueryStash::ActiveRecord.registry.instance_variable_set(:@rules, [])
    QueryStash::ActiveRecord.registry.add_rule(
      /\ASELECT "posts"\.\* FROM "posts" WHERE "posts"\."id" = \d+/,
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
    queries.count { |sql| sql.start_with?(%(SELECT "posts".* FROM "posts" WHERE "posts"."id" = #{id})) }
  end

  it "patches the adapter that was loaded before ActiveRecord::Base" do
    expect(ActiveRecord::ConnectionAdapters::SQLite3Adapter.ancestors)
      .to include(QueryStash::ActiveRecord::AdapterPatch)
  end

  it "serves repeated lookups of a published row from the stash" do
    post = post_class.create!(status: "published", title: "Hello")

    ActiveRecord::Base.with_query_stash do
      expect(post_class.find(post.id).title).to eq("Hello")
      expect(post_class.find(post.id).title).to eq("Hello")
    end

    expect(lookups(post.id)).to eq(1)
    expect(hits).to eq([{ adapter: :active_record, rule: "post_by_id" }])
  end

  it "does not cache rows the TTL callable skips" do
    post = post_class.create!(status: "draft", title: "WIP")

    ActiveRecord::Base.with_query_stash do
      2.times { post_class.find(post.id) }
    end

    expect(lookups(post.id)).to eq(2)
  end

  it "keeps serving the cached row after a write until the TTL expires" do
    post = post_class.create!(status: "published", title: "Before")

    ActiveRecord::Base.with_query_stash do
      post_class.find(post.id)
      post_class.where(id: post.id).update_all(title: "After")

      expect(post_class.find(post.id).title).to eq("Before")
    end

    expect(post_class.find(post.id).title).to eq("After")
  end

  it "leaves queries alone outside a with_query_stash block" do
    post = post_class.create!(status: "published", title: "Hello")

    2.times { post_class.find(post.id) }

    expect(lookups(post.id)).to eq(2)
    expect(hits).to be_empty
  end
end
