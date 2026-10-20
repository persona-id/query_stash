# frozen_string_literal: true

class StashStateJob < ActiveJob::Base
  def perform
    [
      QueryStash::IsolatedState[QueryStash::ActiveRecord[Rails.application]],
      QueryStash::IsolatedState[QueryStash::Mongo[Rails.application]]
    ]
  end
end
