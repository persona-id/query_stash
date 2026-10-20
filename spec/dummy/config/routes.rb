# frozen_string_literal: true

Rails.application.routes.draw do
  get "/posts/:id", to: "posts#show"
  get "/mongo_posts/:id", to: "mongo_posts#show"
end
