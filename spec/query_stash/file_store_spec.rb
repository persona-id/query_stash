# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "logger"
require "active_support/testing/time_helpers"
require "query_stash/file_store"

RSpec.describe QueryStash::FileStore do
  gnu_du = system("du", "-bs", __FILE__, out: File::NULL, err: File::NULL)

  let(:cache_path) { Dir.mktmpdir("query-stash-spec") }
  let(:store) { described_class.new("dummy-label", cache_path, lock_path: File.join(cache_path, "lock")) }
  let(:payload) { "some-value" * 1_000 }

  after do
    # Both outlive the example otherwise, waking for the rest of the suite to `du`/flock a path
    # that is already gone.
    store.instance_variable_get(:@metrics_thread)&.kill
    store.instance_variable_get(:@evictor_thread)&.kill
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

  describe "#fs_usage_bytes" do
    it "grows when an entry is written" do
      skip "needs GNU du" unless gnu_du

      expect { store.write("some-key", payload) }
        .to change { store.send(:fs_usage_bytes) }.by_at_least(1)
    end

    context "when the cache directory has not been created yet" do
      let(:store) do
        described_class.new("dummy-label", File.join(cache_path, "not-created-yet"),
                            lock_path: File.join(cache_path, "lock"))
      end

      before do
        allow(Open3).to receive(:capture3).and_call_original
      end

      it "reports no usage without shelling out" do
        expect(store.send(:fs_usage_bytes)).to eq(0)
        expect(Open3).not_to have_received(:capture3)
      end
    end

    context "when du cannot measure the cache path" do
      let(:logger) { instance_double(Logger, error: nil) }

      before do
        # Built first so the constructor's own measurement doesn't see the stubbed failure.
        store

        allow(Open3).to receive(:capture3)
          .and_return(["", "du: cannot access", instance_double(Process::Status, success?: false)])
        allow(store).to receive(:logger).and_return(logger)
      end

      it "reports no usage" do
        expect(store.send(:fs_usage_bytes)).to eq(0)
        expect(logger).to have_received(:error).with("du: cannot access")
      end
    end
  end

  describe "#usage_bytes" do
    it "measures cache contents already on disk when the store is built" do
      skip "needs GNU du" unless gnu_du

      File.write(File.join(cache_path, "preexisting-entry"), payload)

      expect(store.usage_bytes).to be >= payload.bytesize
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
