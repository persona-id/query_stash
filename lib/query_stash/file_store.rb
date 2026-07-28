# frozen_string_literal: true

require "active_support"
require "active_support/cache"

module QueryStash
  # The evictor deletes empty cache directories out from under concurrent writes, so a rename can
  # land on a path that vanished after `ensure_cache_path`. Rescued here, below
  # `ActiveSupport::Cache::Store#instrument`, so the lost write isn't recorded as an exception on the
  # surrounding cache instrumentation.
  #
  # Reads need no equivalent: `FileStore#read_serialized_entry` already swallows every error and
  # treats it as a miss.
  class FileStore < ::ActiveSupport::Cache::FileStore
    EVICTOR_SLEEP_INTERVAL = 5 * 60

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
    end

    private

    def write_serialized_entry(...)
      super
    rescue Errno::ENOENT
      false
    end
  end
end
