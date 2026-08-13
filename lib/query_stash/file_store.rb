# frozen_string_literal: true

require "open3"
require "active_support"
require "active_support/cache"

module QueryStash
  # The evictor and the other processes sharing this cache path delete files and directories
  # concurrently, so an operation can find its path already gone: a write's rename lands in a
  # directory removed after `ensure_cache_path`, and a read that deletes an expired entry loses the
  # file mid-delete — which ActiveSupport re-raises whenever the key gets rewritten before it can
  # double-check.
  #
  # Both are rescued below `ActiveSupport::Cache::Store#instrument`, so a lost cache entry isn't
  # recorded as an exception on the surrounding cache instrumentation.
  class FileStore < ::ActiveSupport::Cache::FileStore
    EVICTOR_SLEEP_INTERVAL = 5 * 60
    METRICS_SLEEP_INTERVAL = 30

    attr_reader :usage_bytes

    def initialize(label, cache_path, lock_path:, **options)
      super(cache_path, **options)

      # starts background thread to periodically clean up the file cache so it does not grow
      # unbounded.
      @evictor_thread = Thread.start(self) do |file_cache|
        Thread.current.name = "#{label}-evictor"
        loop do
          sleep EVICTOR_SLEEP_INTERVAL
          File.open(lock_path, File::RDWR | File::CREAT) do |f|
            file_cache.cleanup if f.flock(File::LOCK_EX | File::LOCK_NB)
          end
          sleep rand # jitter
        rescue Interrupt
          break
        rescue Errno::ENOENT
          # directory structure may have changed meanwhile, file/dir not found.
          next
        rescue StandardError => e
          # failed to clean up the file cache
          ActiveSupport.error_reporter.report(e, handled: true)
        end
      end

      @usage_bytes = fs_usage_bytes

      @metrics_thread = Thread.start(self) do |_file_cache|
        Thread.current.name = "#{label}-metrics"

        loop do
          # Only update cache stats once every 30 seconds to avoid excessive STAT syscalls
          sleep METRICS_SLEEP_INTERVAL + rand

          @usage_bytes = fs_usage_bytes
        rescue Interrupt
          break
        rescue StandardError => e
          logger&.error(e)
        end
      end
    end

    private

    def fs_usage_bytes
      return 0 unless Dir.exist?(cache_path)

      o, e, s = Open3.capture3("du", cache_path, "-bs")

      if s.success?
        # ex: 128234328   path/to/dir
        o.split(/\W+/).first.to_i
      else
        logger&.error(e)
        0
      end
    end

    def write_serialized_entry(...)
      super
    rescue Errno::ENOENT
      false
    end

    def delete_entry(...)
      super
    rescue Errno::ENOENT
      false
    end
  end
end
