# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "active_support/testing/time_helpers"
require "query_stash/file_store"

RSpec.describe QueryStash::FileStore do
  let(:cache_path) { Dir.mktmpdir("query-stash-spec") }
  let(:store) { described_class.new("dummy-label", cache_path, lock_path: File.join(cache_path, "lock")) }

  after do
    FileUtils.remove_entry(cache_path, true)
  end

  describe "#write" do
    subject { store.write("some-key", "some-value") }

    it "stores the value" do
      expect { subject }.to change { store.read("some-key") }.from(nil).to("some-value")
    end

    context "when the entry directory disappears before the write lands" do
      before do
        # Stands in for the evictor deleting the directory between `ensure_cache_path` and the rename.
        allow(store).to receive(:ensure_cache_path)
      end

      it "reports a failed write, not an exception" do
        payload = nil
        capture_payload = ->(_name, _start, _finish, _id, event_payload) { payload = event_payload }

        result = ActiveSupport::Notifications.subscribed(capture_payload, "cache_write.active_support") { subject }

        expect(result).to be(false)
        expect(payload).not_to include(:exception_object)
      end
    end
  end

  describe "#read" do
    include ActiveSupport::Testing::TimeHelpers

    subject { store.read("some-key") }

    context "when an expired entry is deleted by another process first" do
      before do
        travel_to(Time.now - 300) { store.write("some-key", "some-value", expires_in: 60) }

        # ActiveSupport tolerates a lost delete only while the key stays gone, so leaving the file in
        # place stands in for another process rewriting it before that check.
        allow(File).to receive(:delete).and_raise(Errno::ENOENT)
      end

      it "reports a miss, not an exception" do
        payload = nil
        capture_payload = ->(_name, _start, _finish, _id, event_payload) { payload = event_payload }

        result = ActiveSupport::Notifications.subscribed(capture_payload, "cache_read.active_support") { subject }

        expect(result).to be_nil
        expect(payload).not_to include(:exception_object)
      end
    end
  end
end
