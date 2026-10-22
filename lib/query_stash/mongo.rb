# frozen_string_literal: true

require "digest"
require "json"
require_relative "base"

module QueryStash
  class Mongo < Base
    # What the patch and `wrap` ask of the driver's own objects.
    #
    # @rbs!
    #   # Has a name: a collection, or a database.
    #   interface _Named
    #     def name: () -> String
    #   end
    #
    #   # A `Mongo::Collection::View`, or an aggregation view.
    #   interface _View
    #     def collection: () -> _Named
    #
    #     def database: () -> _Named
    #
    #     def filter: () -> untyped
    #
    #     def options: () -> Hash[Symbol, untyped]
    #
    #     def each: () ?{ (untyped document) -> untyped } -> untyped
    #   end
    #
    #   # A selector to match rules against.
    #   type selector = Hash[Symbol, untyped]

    # ---------------- Constants ----------------
    # Wildcard sentinel for selector patterns
    ANY = Object.new.freeze #: Object

    class MongoFilterRegistry < Registry
      private

      # Pattern semantics:
      #
      # - ANY sentinel:
      #     pattern.equal?(ANY) => match anything as long as the key exists
      #: (untyped actual, untyped pattern) -> bool
      def value_matches_pattern?(actual, pattern)
        # Wildcard – anything goes (key presence already checked by caller)
        return true if pattern.equal?(ANY)

        super
      end
    end

    # Enables the stash for the duration of each request. `application` is the Rails application the
    # middleware stack belongs to; `app` is the next middleware.
    class Middleware
      # @rbs @app: _RackApp
      # @rbs @application: untyped

      #: (_RackApp app, untyped application) -> void
      def initialize(app, application)
        @app = app
        @application = application
      end

      #: (Hash[String, untyped] env) -> untyped
      def call(env)
        QueryStash::Mongo[@application].enable! { @app.call(env) }
      end
    end

    # @rbs module-self _View
    module AdapterPatch
      #: () ?{ (untyped document) -> untyped } -> untyped
      def each(&block)
        QueryStash::Mongo[Rails.application].wrap(self, block) { |&iterate| super(&iterate) }
      end
    end

    # Runs the view's cursor through the stash: `cursor` iterates the view's documents into the block
    # it is given, and `consumer` is the block `each` was called with. (RBS can't say that a block takes
    # a block, so the parameters of `cursor` are not typed.)
    #: (_View view, ?(^(untyped) -> untyped)? consumer) { (?) -> untyped } -> untyped
    def wrap(view, consumer = nil, &cursor)
      rule = rule_for(view)
      # Avoid eager loading the entire result set unless this query actually matches a cache rule.
      # This can cause very quick OOMs if it has to load a whole collection at once.
      return cursor.call(&consumer) unless rule

      documents = read(rule, view) || write(rule, load_documents(&cursor), view)

      consumer ? documents.each(&consumer) : documents.to_enum
    end

    # The rule the view is stashed under, or nil when it isn't to be stashed: the stash is off, or no rule
    # matches its selector.
    #: (_View view) -> Registry::Rule?
    def rule_for(view)
      return unless stashing?

      registry.match_rule(selector_for(view))
    end

    # Based off of #cache_key from Mongo::QueryCache
    # https://github.com/mongodb/mongo-ruby-driver/blob/master/lib/mongo/query_cache.rb#L19
    #: (_View view) -> String
    def cache_key_for(view)
      selector = selector_for(view)
      raw = [
        selector[:collection_name],
        selector[:filter],
        selector[:limit],
        selector[:skip],
        selector[:sort],
        selector[:projection],
        selector[:pipeline]
      ].to_json

      "v1:#{view.database.name}:#{Digest::SHA256.hexdigest(raw)}"
    end

    private

    #: () -> MongoFilterRegistry
    def build_registry
      MongoFilterRegistry.new
    end

    # Based off of #cache_options in Mongo::Collection::View::Iterable
    # https://github.com/mongodb/mongo-ruby-driver/blob/v2.19.3/lib/mongo/collection/view/iterable.rb
    #: (_View view) -> selector
    def selector_for(view)
      # An aggregation view has a pipeline where the others have a filter.
      pipelined = view #: untyped
      {
        collection_name: view.collection.name,
        filter: view.filter,
        limit: view.options[:limit],
        skip: view.options[:skip],
        sort: view.options[:sort],
        projection: view.options[:projection],
        pipeline: pipelined.respond_to?(:pipeline) ? pipelined.pipeline : nil
      }
    end

    #: () { (?) -> untyped } -> Array[untyped]
    def load_documents(&cursor)
      docs = [] #: Array[untyped]
      cursor.call { |doc| docs << doc }
      docs
    end
  end
end
