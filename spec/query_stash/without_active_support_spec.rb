# frozen_string_literal: true

require "open3"
require "rbconfig"

# This process has Rails loaded, so the core is run in a fresh one, where nothing but the core and its
# own dependencies are required.
RSpec.describe "QueryStash without ActiveSupport" do
  let(:lib) { File.expand_path("../../lib", __dir__) }
  let(:script) do
    <<~RUBY
      require "query_stash/base"
      require "query_stash/mongo"
      require "query_stash/active_record"
      require "query_stash/sequel"

      class FakeStore
        def initialize = @entries = {}
        def read(key) = @entries[key]
        def write(key, value, **) = @entries[key] = value
        def clear = @entries.clear
      end

      View = Struct.new(:collection, :database, :filter, :options)
      view = View.new(Struct.new(:name).new("accounts"), Struct.new(:name).new("test_db"),
                      { "token" => "abc" }, { limit: nil, skip: nil, sort: nil, projection: nil })

      mongo = QueryStash::Mongo.new(cache_store: FakeStore.new, enabled: false, raise_on_cache_error: true)
      mongo.registry.add_rule({ collection_name: "accounts" }, name: "accounts", ttl_seconds: 60, ttl_jitter_seconds: 0)
      runs = 0
      read = lambda do
        mongo.wrap(view) do |&iterate|
          runs += 1
          %w[a b].each(&iterate)
        end.to_a
      end

      outside = [read.call, read.call, runs]
      mongo.cache.clear
      runs = 0
      inside = mongo.enable! { [read.call, read.call, runs] }

      sql = QueryStash::ActiveRecord.new(cache_store: FakeStore.new, enabled: false, raise_on_cache_error: true)
      sql.extend(QueryStash::ActiveRecord::InternalExecQuery::Stash)
      sql.registry.add_rule(/SELECT/, name: "selects", ttl_seconds: 60, ttl_jitter_seconds: 0)
      binds = sql.enable! { sql.wrap("SELECT 1", ["bind"]) { :db } }

      db = Sequel.sqlite(query_stash: { cache_store: FakeStore.new, enabled: false, raise_on_cache_error: true })
      db.extension(:query_stash)
      stash = QueryStash::Sequel[db]
      stash.registry.add_rule(/SELECT/, name: "selects", ttl_seconds: 60, ttl_jitter_seconds: 0)
      db.create_table(:t) { String :a }
      db[:t].insert(a: "x")
      sequel_runs = []
      db.loggers << Class.new { define_method(:info) { |message| sequel_runs << message if message.include?("SELECT") } }.new
      rows = stash.enable! { Array.new(2) { db[:t].all } }

      puts [outside, inside, binds, rows, sequel_runs.size].inspect
      puts $LOADED_FEATURES.grep(/active_support/).first(3).inspect
    RUBY
  end

  it "loads and runs the adapters with a plain store and config" do
    output, status = Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)

    expect(status).to be_success, output
    results, loaded_active_support = output.lines.last(2).map(&:chomp)
    expect(results).to eq([[%w[a b], %w[a b], 2], [%w[a b], %w[a b], 1], :db, [[{ a: "x" }], [{ a: "x" }]], 1].inspect)
    expect(loaded_active_support).to eq("[]")
  end
end
