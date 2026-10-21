# frozen_string_literal: true

require "active_support"
require_relative "query_stash/version"
require_relative "query_stash/railtie" if defined?(Rails::Railtie)

module QueryStash
  class Error < StandardError; end
end
