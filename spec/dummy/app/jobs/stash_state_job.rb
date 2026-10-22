# frozen_string_literal: true

class StashStateJob < ActiveJob::Base
  def perform
    [
      ActiveSupport::IsolatedExecutionState[QueryStash::ActiveRecord[Rails.application]],
      ActiveSupport::IsolatedExecutionState[QueryStash::Mongo[Rails.application]],
      ActiveSupport::IsolatedExecutionState[QueryStash::Sequel[Rails.application]]
    ]
  end
end
