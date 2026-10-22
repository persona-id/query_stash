# frozen_string_literal: true

require "tmpdir"

RSpec.describe QueryStash::Sequel, database: :active_record do
  let(:db) { SequelDatabase.db }
  let(:posts) { db[:sequel_posts] }
  let(:stash) { reset_app_stash(described_class) }
  let(:events) { [] }

  # Quoting differs per engine, so match on the table's name only. (Sequel also looks the table up in the
  # catalog the first time it needs its schema, which names the table too.)
  def selects
    SequelDatabase.queries.messages.grep(/SELECT.*sequel_posts/).grep_v(/pg_|information_schema/)
  end

  before do
    posts.delete
    SequelDatabase.queries.messages.clear
    stash.registry.add_rule(/\ASELECT .*sequel_posts/, name: "posts", ttl_seconds: 60, ttl_jitter_seconds: 0)
  end

  it "builds a Registry::Sql" do
    expect(build_stash(described_class).registry).to be_a(QueryStash::Registry::Sql)
  end

  it "patches the datasets of a database that loads the extension" do
    expect(db.dataset_class.ancestors).to include(QueryStash::Sequel::DatasetPatch)
  end

  it "indexes the stash by the database" do
    other = Sequel.sqlite
    own = described_class.new(cache_store: ActiveSupport::Cache::MemoryStore.new, enabled: true)
    own.registry.add_rule(/\ASELECT/, name: "all", ttl_seconds: 60, ttl_jitter_seconds: 0)
    described_class.set(other, own)
    other.extension(:query_stash)

    other["SELECT 1 AS one"].all

    expect(described_class[other]).to be(own)
    expect(described_class[db]).to be(stash)
    expect(own.cache.instance_variable_get(:@data).size).to eq(1)
  end

  it "stashes a database that loads the extension with the app's stash" do
    other = Sequel.sqlite
    other.extension(:query_stash)

    expect(described_class[other]).to be(stash)
  end

  describe "without the railtie's stash builder" do
    around do |example|
      builder = described_class.stash_builder
      described_class.stash_builder = described_class::DEFAULT_STASH_BUILDER
      example.run
    ensure
      described_class.stash_builder = builder
    end

    it "builds the database's own stash from its :query_stash option" do
      store = ActiveSupport::Cache::MemoryStore.new
      other = Sequel.sqlite(query_stash: { cache_store: store, enabled: true })
      other.extension(:query_stash)
      described_class[other].registry.add_rule(/\ASELECT/, name: "all", ttl_seconds: 60, ttl_jitter_seconds: 0)

      other["SELECT 1 AS one"].all

      expect(described_class[other]).to be_a(described_class).and have_attributes(cache: store, enabled: true)
      expect(described_class[other]).not_to be(stash)
      expect(store.instance_variable_get(:@data).size).to eq(1)
    end

    it "keeps a stash set for the database already" do
      other = Sequel.sqlite
      own = described_class.new(cache_store: ActiveSupport::Cache::MemoryStore.new)
      described_class.set(other, own)

      other.extension(:query_stash)

      expect(described_class[other]).to be(own)
    end

    it "asks for the option when the database has none" do
      expect { Sequel.sqlite.extension(:query_stash) }.to raise_error(QueryStash::Error, /:query_stash option/)
    end
  end

  it "loads into a database with `extension`, once" do
    other = Sequel.sqlite

    expect(other.extension(:query_stash)).to be(other)
    expect(other.dataset_class.ancestors.count(QueryStash::Sequel::DatasetPatch)).to eq(1)
  end

  describe "stashing" do
    let!(:id) { posts.insert(status: "published", title: "Hello") }

    it "does not stash outside of enable!, when the stash is not enabled" do
      allow(stash).to receive(:enabled).and_return(false)

      2.times { posts.where(id: id).all }

      expect(selects.size).to eq(2)
    end

    it "serves a repeated query from the stash" do
      stash.enable! do
        expect(posts.where(id: id).all).to eq([{ id: id, status: "published", title: "Hello" }])
        expect(posts.where(id: id).all).to eq([{ id: id, status: "published", title: "Hello" }])
      end

      expect(selects.size).to eq(1)
    end

    it "does not stash while disabled inside an enabled block" do
      stash.enable! { stash.disable! { 2.times { posts.where(id: id).all } } }

      expect(selects.size).to eq(2)
    end

    it "serves what is not a row of hashes the dataset hands out: first, get, count" do
      stash.enable! do
        2.times do
          expect(posts.where(id: id).first[:title]).to eq("Hello")
          expect(posts.where(id: id).get(:title)).to eq("Hello")
          expect(posts.where(id: id).count).to eq(1)
        end
      end

      expect(selects.size).to eq(3)
    end

    it "serves raw SQL" do
      stash.enable! { 2.times { expect(db["SELECT title FROM sequel_posts"].all).to eq([{ title: "Hello" }]) } }

      expect(selects.size).to eq(1)
    end

    it "serves an empty result as well" do
      stash.enable! { 2.times { expect(posts.where(id: id + 1000).all).to eq([]) } }

      expect(selects.size).to eq(1)
    end

    it "stores what a model's row_proc is given, and gives it back to it" do
      model = Class.new(Sequel::Model(posts))

      stash.enable! do
        2.times { expect(model.where(id: id).first).to be_a(model).and have_attributes(title: "Hello") }
      end

      expect(selects.size).to eq(1)
    end

    it "does not serve a query no rule matches" do
      stash.enable! { 2.times { db["SELECT 1 AS one"].all } }

      expect(SequelDatabase.queries.messages.grep(/SELECT 1/).size).to eq(2)
    end

    it "does not stash what is not a SELECT" do
      stash.registry.add_rule(/INSERT/i, name: "inserts", ttl_seconds: 60, ttl_jitter_seconds: 0)

      stash.enable! { 2.times { posts.insert(title: "More") } }

      expect(posts.count).to eq(3)
    end

    it "does not stash queries with bind variables" do
      stash.enable! do
        2.times { expect(posts.where(id: :$id).call(:first, id: id)[:title]).to eq("Hello") }
      end

      expect(selects.size).to eq(2)
    end

    it "does not stash prepared statements" do
      prepared = posts.where(id: :$id).prepare(:first, :sequel_post_by_id)

      reads = events_of("cache_read.query_stash") do
        stash.enable! { 2.times { expect(prepared.call(id: id)[:title]).to eq("Hello") } }
      end

      expect(reads).to be_empty
    end

    it "keeps the stash of a rule apart from what another database has under the same SQL" do
      Dir.mktmpdir do |dir|
        other = Sequel.sqlite(File.join(dir, "other.sqlite3"))
        other.extension(:query_stash)
        other.create_table(:sequel_posts) { String :title }
        other[:sequel_posts].insert(title: "Other")

        stash.enable! do
          expect(posts.select(:title).all).to eq([{ title: "Hello" }])
          expect(other[:sequel_posts].select(:title).all).to eq([{ title: "Other" }])
        end
      ensure
        other&.disconnect
      end
    end

    it "stores only what the rule's ttl_seconds is for, and skips the rest" do
      stash.registry.delete_rule("posts")
      stash.registry.add_rule(
        /\ASELECT .*sequel_posts/, name: "published",
                                   ttl_seconds: ->(rows) { rows.all? { |row| row[:status] == "published" } ? 60 : 0 },
                                   ttl_jitter_seconds: 0
      )
      draft = posts.insert(status: "draft", title: "Draft")

      stash.enable! do
        2.times { posts.where(id: id).all }
        2.times { posts.where(id: draft).all }
      end

      expect(selects.size).to eq(3)
    end

    it "does not serve a query of a rule that is not enabled" do
      stash.registry.delete_rule("posts")
      stash.registry.add_rule(/\ASELECT .*sequel_posts/, name: "off", ttl_seconds: 60, ttl_jitter_seconds: 0,
                                                         enabled: -> { false })

      stash.enable! { 2.times { posts.where(id: id).all } }

      expect(selects.size).to eq(2)
    end

    it "emits cache_read, cache_miss and cache_hit with the adapter's name" do
      emitted = []
      subscriber = ActiveSupport::Notifications.subscribe(/\Acache_.*\.query_stash\z/) do |event|
        emitted << [event.name.delete_suffix(".query_stash"), event.payload]
      end
      stash.enable! { 2.times { posts.where(id: id).all } }
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(emitted).to eq(
        [["cache_read", { adapter: :sequel, rule: "posts", hit: false }],
         ["cache_miss", { adapter: :sequel, rule: "posts" }],
         ["cache_read", { adapter: :sequel, rule: "posts", hit: true }],
         ["cache_hit", { adapter: :sequel, rule: "posts" }]]
      )
    end
  end
end
