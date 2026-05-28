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
end
