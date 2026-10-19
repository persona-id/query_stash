# frozen_string_literal: true

class PostsController < ActionController::Base
  def show
    render plain: Post.find(params[:id]).title
  end
end
