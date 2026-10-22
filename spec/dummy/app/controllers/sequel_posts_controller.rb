# frozen_string_literal: true

class SequelPostsController < ActionController::Base
  def show
    render plain: SequelDatabase.db[:sequel_posts].where(id: params[:id]).get(:title)
  end
end
