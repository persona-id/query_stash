# frozen_string_literal: true

require_relative "query_stash/version"

module QueryStash
  class Error < StandardError; end

  class << self
    attr_accessor :raise_errors
  end
end
