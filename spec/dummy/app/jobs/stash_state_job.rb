# frozen_string_literal: true

class StashStateJob < ActiveJob::Base
  def perform
    [
      QueryStash::IsolatedState[:query_stash_active_record_enabled],
      QueryStash::IsolatedState[:query_stash_mongo_enabled]
    ]
  end
end
