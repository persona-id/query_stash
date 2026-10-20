# frozen_string_literal: true

class MongoPostsController < ActionController::Base
  def show
    render plain: MongoPost.find(params[:id]).title
  end
end
