# frozen_string_literal: true

class StashStateJob < ActiveJob::Base
  def perform
    [
      ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]],
      ActiveSupport::IsolatedExecutionState[QueryStash::Mongo[Rails.application]]
    ]
  end
end
