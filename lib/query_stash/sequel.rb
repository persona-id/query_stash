# frozen_string_literal: true

require "digest"
require "sequel/core"
require_relative "base"
require_relative "registry/sql"

module QueryStash
  # Stashes the `SELECT`s of Sequel datasets, matched by regexp like the ActiveRecord ones.
  #
  # A database stashes once it loads the extension, which gives it a stash of its own, from the options in its
  # `:query_stash` option:
  #
  #   DB = Sequel.connect(url, query_stash: { cache_store: store, enabled: true })
  #   DB.extension(:query_stash)
  #   QueryStash::Sequel[DB].configure { |rules| ... }
  #
  # (`cache_store:` and the options of `QueryStash::Base#initialize`.) With sequel-rails, the railtie makes it
  # the app's stash instead: `Sequel::Model.db.extension(:query_stash)` is all it takes for another database.
  #
  # (Inside this class `Sequel` is this class: the library is `::Sequel`.)
  class Sequel < Base
    # What the patch asks of Sequel's own objects.
    #
    # @rbs!
    #   # A dataset, as far as the patch and the stash look at it.
    #   interface _Dataset
    #     def fetch_rows: (String sql) { (Hash[Symbol, untyped] row) -> untyped } -> untyped
    #
    #     def db: () -> ::Sequel::Database
    #
    #     def opts: () -> Hash[Symbol, untyped]
    #
    #     def is_a?: (Module mod) -> bool
    #   end

    CACHEABLE_SQL_REGEX = /\ASELECT/i #: Regexp
    private_constant :CACHEABLE_SQL_REGEX

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
        QueryStash::Sequel[@application].enable! { @app.call(env) }
      end
    end

    # Included in the dataset class of each database that loads the extension. Every query a dataset runs
    # goes through `fetch_rows`, which each adapter defines for its own dataset class, so this has to sit
    # in front of those rather than in `Sequel::Dataset`.
    #
    # A database's stash is the one set for the database itself, which the extension does (see
    # `QueryStash::Sequel.stash_builder`).
    # @rbs module-self _Dataset
    module DatasetPatch
      #: (String sql) { (Hash[Symbol, untyped] row) -> untyped } -> untyped
      def fetch_rows(sql, &consumer)
        QueryStash::Sequel[db].wrap(self, sql, consumer) { |&rows| super(sql, &rows) }
      end
    end

    # What builds the stash of a database that loads the extension without one: from its `:query_stash`
    # option. (The railtie replaces it, to hand out the app's stash.)
    DEFAULT_STASH_BUILDER = lambda do |db|
      options = db.opts[:query_stash]
      cache_store = options.is_a?(Hash) && options[:cache_store]
      raise Error, "Give the database a :query_stash option with a :cache_store, to stash it" unless cache_store

      QueryStash::Sequel.new(cache_store: cache_store, **options.except(:cache_store))
    end #: ^(::Sequel::Database) -> QueryStash::Sequel

    class << self
      # @rbs self.@stash_builder: ^(::Sequel::Database) -> QueryStash::Sequel

      # Builds the stash of a database that loads the extension without having one.
      #: () -> (^(::Sequel::Database) -> QueryStash::Sequel)
      def stash_builder
        @stash_builder ||= DEFAULT_STASH_BUILDER
      end

      #: (^(::Sequel::Database) -> QueryStash::Sequel builder) -> void
      attr_writer :stash_builder
    end

    ::Sequel::Database.register_extension(:query_stash) do |db|
      QueryStash::Sequel.set(db, QueryStash::Sequel.stash_builder.call(db)) unless QueryStash::Sequel.key?(db)
      db.extend_datasets(DatasetPatch)
    end

    # Runs the dataset's query through the stash: `cursor` fetches its rows into the block it is given,
    # and `consumer` is the block `fetch_rows` was called with. (RBS can't say that a block takes a block,
    # so the parameters of `cursor` are not typed.)
    #: (_Dataset dataset, String sql, (^(Hash[Symbol, untyped]) -> untyped)? consumer) { (?) -> untyped } -> untyped
    def wrap(dataset, sql, consumer, &cursor)
      rule = rule_for(dataset, sql)
      # Avoid eager loading every row unless this query actually matches a rule.
      return cursor.call(&consumer) unless rule

      rows = read(rule, dataset, sql) || write(rule, load_rows(&cursor), dataset, sql)
      rows.each(&consumer)
    end

    # The rule the query is stashed under, or nil when it isn't to be stashed: the stash is off, it has
    # binds or runs through a cursor (not supported), it is not a SELECT, or no rule matches it.
    #: (_Dataset dataset, String sql) -> Registry::Rule?
    def rule_for(dataset, sql)
      return unless stashing?
      return if bound?(dataset) || dataset.opts[:cursor]
      return unless CACHEABLE_SQL_REGEX.match?(sql)

      rule = registry.match_rule(sql)
      rule if rule && (rule.enabled.nil? || rule.enabled.call)
    end

    # The same SQL is not the same query on another database, or on another server of the same one.
    #: (_Dataset dataset, String sql) -> String
    def cache_key_for(dataset, sql)
      db = dataset.db
      database = [db.database_type, db.opts[:host], db.opts[:database]].join("/")

      "v1:#{dataset.opts[:server] || :default}:#{database}:#{Digest::SHA256.hexdigest(sql)}"
    end

    private

    #: () -> Registry::Sql
    def build_registry
      Registry::Sql.new
    end

    # Whether the dataset is a prepared statement, or has bind variables.
    #: (_Dataset dataset) -> bool
    def bound?(dataset)
      options = dataset.opts
      !!(options[:bind_vars] || options[:bind_arguments] || dataset.is_a?(::Sequel::Dataset::PreparedStatementMethods))
    end

    #: () { (?) -> untyped } -> Array[Hash[Symbol, untyped]]
    def load_rows(&cursor)
      rows = [] #: Array[Hash[Symbol, untyped]]
      cursor.call { |row| rows << row }
      rows
    end
  end
end
