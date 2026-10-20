# frozen_string_literal: true

class MongoPost
  include Mongoid::Document

  field :status, type: String
  field :title, type: String
end
