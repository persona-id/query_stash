# frozen_string_literal: true

require "query_stash/active_record"
require "query_stash/mongo"
require "query_stash/rack"

RSpec.describe QueryStash::Rack::Middleware do
  describe "#call" do
    it "enables the stash for both adapters during the request and restores it afterwards" do
      seen = nil
      app = lambda do |_env|
        seen = [
          Thread.current[:query_stash_active_record_enabled],
          Thread.current[:query_stash_mongo_enabled]
        ]
        [200, {}, ["ok"]]
      end
      Thread.current[:query_stash_active_record_enabled] = nil
      Thread.current[:query_stash_mongo_enabled] = nil

      response = described_class.new(app).call({})

      expect(response).to eq([200, {}, ["ok"]])
      expect(seen).to eq([true, true])
      expect(Thread.current[:query_stash_active_record_enabled]).to be_nil
      expect(Thread.current[:query_stash_mongo_enabled]).to be_nil
    end
  end
end
