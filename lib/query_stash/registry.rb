# frozen_string_literal: true

module QueryStash
  class Registry
    # @rbs!
    #   # How long a result is kept: a number of seconds, or something that works it out from the result.
    #   type ttl = _ToI | ^(untyped result) -> _ToI

    Rule = Data.define(
      :selector, #: untyped
      :name, #: String
      :ttl_seconds, #: ttl
      :ttl_jitter_seconds, #: ttl
      :enabled, #: (^() -> boolish)?
      :store #: _CacheStore?
    )

    class Rule
      # The seconds a result is kept for, for `result`.
      #: (untyped result) -> Integer
      def ttl_seconds_for(result)
        seconds = ttl_seconds #: untyped
        seconds.respond_to?(:call) ? seconds.call(result).to_i : seconds.to_i
      end

      # The jitter added to that, for `result`.
      #: (untyped result) -> Integer
      def ttl_jitter_seconds_for(result)
        seconds = ttl_jitter_seconds #: untyped
        seconds.respond_to?(:call) ? seconds.call(result).to_i : seconds.to_i
      end
    end

    # What `set_rule_defaults` can set: the options of `add_rule` other than the selector and the name.
    RULE_DEFAULTS = %i[ttl_seconds ttl_jitter_seconds enabled store].freeze #: Array[Symbol]

    # What an option of `add_rule` is when it is not given (`nil` is a value too: `enabled: nil`).
    UNSET = Object.new.freeze #: Object

    # @rbs @rules: Array[Rule]
    # @rbs @rule_defaults: Hash[Symbol, untyped]

    attr_reader :rules #: Array[Rule]

    #: () -> void
    def initialize
      @rules = []
      @rule_defaults = {}
    end

    # Sets what the rules added from now on take for the options they don't give, so that a block of rules
    # needs to say only what is different about each one:
    #
    #   registry.set_rule_defaults(ttl_seconds: 60, ttl_jitter_seconds: 10)
    #   registry.add_rule(/SELECT .*users/, name: "users")                   # 60 seconds, 10 of jitter
    #   registry.add_rule(/SELECT .*orders/, name: "orders", ttl_seconds: 5) # 5 seconds, 10 of jitter
    #
    # The rules that exist are left as they are. A later call changes only the options it names, and `nil`
    # takes a default away.
    #
    # @rbs **defaults: untyped
    # @rbs return: Hash[Symbol, untyped]
    def set_rule_defaults(**defaults)
      unknown = defaults.keys - RULE_DEFAULTS
      unless unknown.empty?
        raise Error, "Unknown rule defaults: #{unknown.join(", ")} (use #{RULE_DEFAULTS.join(", ")})"
      end

      @rule_defaults = @rule_defaults.merge(defaults).compact
    end

    # `ttl_seconds` and `ttl_jitter_seconds` are required, unless `set_rule_defaults` gave them.
    #
    # @rbs selector: untyped
    # @rbs name: String
    # @rbs ttl_seconds: ttl | Object
    # @rbs ttl_jitter_seconds: ttl | Object
    # @rbs enabled: (^() -> boolish)? | Object
    # @rbs store: _CacheStore? | Object
    # @rbs return: Array[Rule]
    def add_rule(
      selector, # required
      name:,
      ttl_seconds: UNSET,
      ttl_jitter_seconds: UNSET,
      enabled: UNSET,
      store: UNSET
    )
      raise Error, "Rule name is required" if name.nil? || name.empty?

      raise Error, "Rule name #{name.inspect} is already taken" if @rules.any? { |r| r.name == name }

      given = { ttl_seconds: ttl_seconds, ttl_jitter_seconds: ttl_jitter_seconds, enabled: enabled, store: store }
      given = given.reject { |_, value| UNSET.equal?(value) }
      options = { enabled: nil, store: nil }.merge(@rule_defaults, given) #: Hash[Symbol, untyped]
      %i[ttl_seconds ttl_jitter_seconds].each do |required|
        raise Error, "Rule #{name.inspect} needs #{required}, or a default for it" if options[required].nil?
      end

      @rules << Rule.new(
        selector: selector,
        name: name,
        ttl_seconds: options[:ttl_seconds],
        ttl_jitter_seconds: options[:ttl_jitter_seconds],
        enabled: options[:enabled],
        store: options[:store]
      )
    end

    #: (String name) -> Array[Rule]
    def delete_rule(name)
      @rules.delete_if { |r| r.name == name }
    end

    # Selector / options / collection-based lookup
    #: (untyped selector) -> Rule?
    def match_rule(selector)
      @rules.detect do |rule|
        value_matches_pattern?(selector, rule.selector)
      end
    end

    private

    # Pattern matching for hashes.
    #
    # `pattern` is a subset / pattern-form of `full`:
    # - wildcards and special values are interpreted via value_matches_pattern?
    #
    #: (Hash[untyped, untyped] full, Hash[untyped, untyped] pattern) -> bool
    def hash_matches_pattern?(full, pattern)
      pattern.all? do |k, expected|
        full.key?(k) && value_matches_pattern?(full[k], expected)
      end
    end

    # Pattern semantics:
    #
    # - Proc:
    #     pattern.call(actual) must be truthy
    # - Regexp:
    #     actual.to_s must match pattern
    # - Hash:
    #     pattern is a nested hash pattern, recurse
    # - Array:
    #     pattern is a "prefix" array pattern:
    #       - pattern length <= actual length
    #       - each element is matched via value_matches_pattern?
    # - Fallback:
    #     actual == pattern
    #
    #: (untyped actual, untyped pattern) -> bool
    def value_matches_pattern?(actual, pattern)
      # Proc – fully custom predicate (Note: ANY is not a Proc)
      return !!pattern.call(actual) if pattern.respond_to?(:call)

      # Regexp – string-like match
      return pattern.match?(actual.to_s) if pattern.is_a?(Regexp)

      # Hash – recursive hash pattern
      return hash_matches_pattern?(actual, pattern) if pattern.is_a?(Hash) && actual.is_a?(Hash)

      # Array – element-wise prefix pattern
      if pattern.is_a?(Array) && actual.is_a?(Array)
        return false if pattern.length > actual.length

        return pattern.each_with_index.all? do |pat_elem, idx|
          value_matches_pattern?(actual[idx], pat_elem)
        end
      end

      # Fallback: strict equality
      actual == pattern
    end
  end
end
