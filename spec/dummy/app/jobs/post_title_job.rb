# frozen_string_literal: true

class PostTitleJob < ActiveJob::Base
  def perform(id)
    Post.find(id).title
  end
end
