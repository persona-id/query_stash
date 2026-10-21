# frozen_string_literal: true

require "active_support"
require "active_support/isolated_execution_state"
require_relative "query_stash/version"
require_relative "query_stash/railtie" if defined?(Rails::Railtie)

module QueryStash
  class Error < StandardError; end

  module IsolatedState
    extend self

    def fetch(key, &block)
      if ActiveSupport::IsolatedExecutionState.key?(key)
        self[key]
      else
        block.call
      end
    end

    def [](key)
      ActiveSupport::IsolatedExecutionState[key]
    end

    def wrap(**values)
      previous = values.to_h { |key, _| [key, self[key]] }
      values.each { |key, value| ActiveSupport::IsolatedExecutionState[key] = value }
      yield
    ensure
      previous&.each do |key, value|
        if value.nil?
          ActiveSupport::IsolatedExecutionState.delete(key)
        else
          ActiveSupport::IsolatedExecutionState[key] = value
        end
      end
    end
  end
end
