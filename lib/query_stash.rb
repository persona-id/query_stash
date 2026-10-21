# frozen_string_literal: true

require_relative "query_stash/version"
require_relative "query_stash/railtie" if defined?(Rails::Railtie)

module QueryStash
  # What a stash needs from the objects it is given. None of them has to be an ActiveSupport one: the
  # railtie hands over the ActiveSupport ones, and anything that responds the same way works.
  #
  # @rbs!
  #   # Where `enable!` and `disable!` keep what they set, like `ActiveSupport::IsolatedExecutionState`.
  #   interface _IsolatedState
  #     def []: (untyped key) -> untyped
  #
  #     def []=: (untyped key, untyped value) -> untyped
  #
  #     def key?: (untyped key) -> bool
  #
  #     def delete: (untyped key) -> untyped
  #   end
  #
  #   # Where results are kept, like an `ActiveSupport::Cache::Store`. `write` is given `expires_in:`.
  #   interface _CacheStore
  #     def read: (String key) -> untyped
  #
  #     def write: (String key, untyped value, ?Hash[Symbol, untyped] options) -> untyped
  #
  #     def clear: () -> untyped
  #   end
  #
  #   # Told about what the stash does, like `ActiveSupport::Notifications`.
  #   interface _Instrumenter
  #     def instrument: (String name, ?Hash[Symbol, untyped] payload) ?{ (Hash[Symbol, untyped]) -> untyped } -> untyped
  #   end
  #
  #   # Told about the errors the stash handles, like `ActiveSupport.error_reporter`.
  #   interface _ErrorReporter
  #     def report: (Exception error, ?handled: bool) -> untyped
  #   end
  #
  #   # The next middleware.
  #   interface _RackApp
  #     def call: (Hash[String, untyped] env) -> untyped
  #   end

  class Error < StandardError; end
end
