# frozen_string_literal: true

require_relative "../registry"

module QueryStash
  class Registry
    # The rules of the adapters that stash SQL: a rule's selector is a regexp, matched against the query.
    class Sql < Registry
      # @rbs override
      def add_rule(regex, ...)
        raise Error, "Regex must be a Regexp, got #{regex.class}" if regex.class != Regexp

        super
      end
    end
  end
end
