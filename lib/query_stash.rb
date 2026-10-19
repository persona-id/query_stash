# frozen_string_literal: true

require "active_support"
require "active_support/isolated_execution_state"
require_relative "query_stash/version"
require_relative "query_stash/railtie" if defined?(Rails::Railtie)

module QueryStash
  class Error < StandardError; end

  # Default store for the enabled flags. Threads spawned inside a
  # `with_query_stash` block do not inherit it; assign `QueryStash.state` an
  # object with the same `[]` and `wrap` methods to propagate the flags.
  module IsolatedState
    extend self

    def [](key)
      ActiveSupport::IsolatedExecutionState[key]
    end

    def wrap(**values)
      previous = values.to_h { |key, _| [key, self[key]] }
      values.each { |key, value| ActiveSupport::IsolatedExecutionState[key] = value }
      yield
    ensure
      previous&.each { |key, value| ActiveSupport::IsolatedExecutionState[key] = value }
    end
  end

  class << self
    attr_writer :state

    def state
      @state ||= IsolatedState
    end
  end
end
