# frozen_string_literal: true

RSpec.describe QueryStash::Base do
  # Records what a stash does to its isolated state, in a plain hash.
  let(:recording_state) do
    Class.new do
      attr_reader :values, :writes

      def initialize
        @values = {}
        @writes = []
      end

      def [](key) = @values[key]

      def []=(key, value)
        @writes << value
        @values[key] = value
      end

      def key?(key) = @values.key?(key)

      def delete(key) = @values.delete(key)
    end.new
  end

  describe "isolated state" do
    let(:stash) { build_stash(QueryStash::ActiveRecord, isolated_state: recording_state) }

    it "is where enable! and disable! keep their value, keyed by the stash" do
      stash.enable! { expect(recording_state[stash]).to be(true) }
      stash.disable! { expect(recording_state[stash]).to be(false) }

      expect(recording_state.writes).to eq([true, false])
    end

    it "is emptied again once the block ends" do
      stash.enable! { stash.disable! { nil } }

      expect(recording_state.values).to be_empty
    end

    it "puts back the value of the enclosing block" do
      stash.disable! do
        stash.enable! { nil }

        expect(recording_state[stash]).to be(false)
      end
    end

    it "is cleaned up when the block raises" do
      expect { stash.enable! { raise "boom" } }.to raise_error("boom")

      expect(recording_state.values).to be_empty
    end

    it "is what the stash follows, falling back to enabled when it has no value" do
      stash = build_stash(QueryStash::ActiveRecord, isolated_state: recording_state, enabled: false)
      stash.registry.add_rule(/SELECT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0)
      queries = 0

      2.times { stash.wrap("SELECT 1", []) { queries += 1 } }
      expect(queries).to eq(2)

      stash.enable! { 2.times { stash.wrap("SELECT 1", []) { queries += 1 } } }
      expect(queries).to eq(3)
    end

    it "does not touch ActiveSupport::IsolatedExecutionState" do
      stash.enable! { expect(ActiveSupport::IsolatedExecutionState.key?(stash)).to be(false) }
    end
  end

  describe "the default isolated state" do
    let(:stash) { build_stash(QueryStash::ActiveRecord, isolated_state: nil, enabled: false) }

    before { stash.registry.add_rule(/SELECT/, name: "test", ttl_seconds: 60, ttl_jitter_seconds: 0) }

    def stashes?(from_stash = stash)
      queries = 0
      2.times { from_stash.wrap("SELECT 1", []) { queries += 1 } }
      queries == 1
    end

    it "is shared by the fibers of a thread" do
      stash.enable! do
        expect(Fiber.new { stashes? }.resume).to be(true)
      end
    end

    it "is not seen by other threads, which follow enabled" do
      stash.enable! do
        expect(Thread.new { stashes? }.value).to be(false)
      end
    end

    it "is restored after the block" do
      stash.enable! { nil }

      expect(stashes?).to be(false)
    end
  end

  describe QueryStash::Base::ThreadVariableState do
    subject(:state) { described_class.new }

    it "stores values under any object" do
      key = Object.new
      state[key] = :value

      expect(state[key]).to eq(:value)
      expect(state.key?(key)).to be(true)
    end

    it "tells a stored nil or false from a missing key" do
      state[:flag] = false

      expect(state.key?(:flag)).to be(true)
      expect(state.key?(:other)).to be(false)
    end

    it "deletes values" do
      state[:flag] = true
      state.delete(:flag)

      expect(state.key?(:flag)).to be(false)
    end

    it "keeps the values of each thread apart" do
      state[:flag] = true

      expect(Thread.new { [state.key?(:flag), state[:flag]] }.value).to eq([false, nil])
    end

    it "shares the values of a thread with its fibers" do
      state[:flag] = true

      expect(Fiber.new { state[:flag] }.resume).to be(true)
    end
  end
end
