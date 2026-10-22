# QueryStash

Cross-request query result caching for the handful of hot, slow-changing lookups you choose.

Currently shipping with adapters for [activerecord](https://rubygems.org/gems/activerecord), [sequel](https://rubygems.org/gems/sequel) and [mongo](https://rubygems.org/gems/mongo).

QueryStash can keep the result of an allowlisted query across requests and jobs, for a TTL you compute from the result itself, in a store of your choosing. It hooks the database adapter (and the Sequel and Mongo drivers), so call sites don't need to change: `Organization.find(id)` is served from the stash when a rule matches it.

```ruby
QueryStash::ActiveRecord[Rails.application].configure do |rules|
  rules.add_rule(
    /\ASELECT "plans"\.\* FROM "plans" WHERE "plans"\."id" = /,
    name: "plan_by_id",
    ttl_seconds: ->(result) { result.rows.any? ? 60 : 0 }, # don't cache "not found"
    ttl_jitter_seconds: 10
  )
end
```

This gem was extracted from code we've been running in production at [Persona](https://withpersona.com).

## When to use it, and when not to

Use it for point lookups that are read far more often than they change, and where a bounded amount of staleness is acceptable.

What it does not do:

- **No invalidation.** Entries leave on TTL (plus jitter) or eviction. A write does not clear the stash, so a read after a write can return the old row until the TTL runs out. Wrap read-after-write code in `disable!`, or don't stash those queries.
- **Inlined SQL only.** Queries with bind parameters are passed through untouched. Use an adapter or configuration that inlines values (Trilogy and mysql2 do by default; set `prepared_statements: false` for SQLite or PostgreSQL).
- **`SELECT` only**, matched with `/\ASELECT/i`. SQL that starts with a comment, whitespace or a `WITH` clause is never stashed.
- **Not transaction-aware.** A matching read inside a transaction can be served from the stash instead of seeing the transaction's own writes.
- **`load_async` queries bypass it.**
- The ActiveRecord cache key is the SQL plus `ActiveRecord::Base.current_shard`. It does not include the role or the database name.

## Installation

```sh
bundle add query_stash
```

ActiveRecord 7.2 or more recent and Ruby 3.3 or more recent are supported.

## Usage

### Turning it on and off

#### Rails

In rails, `config.query_stash.enabled`, (true by default) decides whether queries are stashed. With the default, every query that matches a rule is stashed, including in requests, active jobs, the console, rake tasks and migrations.

```ruby
# config/development.rb
config.query_stash.enabled = false
```

`enable!` and `disable!` can override it for the duration of a block:

```ruby
QueryStash::ActiveRecord[Rails.application].enable! do
  run_job
end
```

Opt out where reads must see their own writes:

```ruby
QueryStash::ActiveRecord[Rails.application].disable! do
  record.update!(status: "active")
  Record.find(record.id) # straight from the database
end
```

### ActiveRecord rules

Configure their rules from an initializer.

Rules match the SQL with a `Regexp`, first match wins:

```ruby
QueryStash::ActiveRecord[Rails.application].configure do |rules|
  rules.add_rule(
    /\ASELECT "templates"\.\* FROM "templates" WHERE "templates"\."id" = /,
    name: "published_template_by_id",
    ttl_seconds: ->(result) { result.to_a.all? { |row| row["status"] == "published" } ? 1.day : 0 },
    ttl_jitter_seconds: 1.hour,
    enabled: -> { Flipper.enabled?(:stash_templates) }
  )
end
```
Besides the regex, the following parameters are accepted as keyword arguments:
- `name` identifies the rule.
- `ttl_seconds` and `ttl_jitter_seconds` are integers or callables that receive the uncached result. A TTL of 0 or less means "don't cache this result" (a *skip*). Entries are written with `expires_in: ttl_seconds + rand(ttl_jitter_seconds)`, so entries for a hot rule don't all expire at once.
- `enabled` turns a single rule off without removing it.

### Sequel rules

The Sequel adapter works like the ActiveRecord one: rules are regexps matched against the SQL a dataset is about to run, only `SELECT`s are stashed, and queries with bind variables or prepared statements (and PostgreSQL cursors) are passed through. A stashed query is loaded in full, so a rule is not for a streamed result set.

```ruby
QueryStash::Sequel[Rails.application].configure do |rules|
  rules.add_rule(
    /\ASELECT \* FROM `plans` WHERE \(`id` = \d+\)/,
    name: "plan_by_id",
    ttl_seconds: ->(rows) { rows.any? ? 60 : 0 }, # don't cache "not found"
    ttl_jitter_seconds: 10
  )
end
```

`ttl_seconds` and `ttl_jitter_seconds` callables receive the rows: an array of hashes, before any model is built from them. The cache key is the SQL, the database (adapter, host and name) and the server the dataset uses. Use whatever quoting your Sequel database does when you write the regexp: `db["SELECT 1"].sql` shows it.

A database is stashed once it loads the extension, which gives it a stash of its own:

```ruby
DB = Sequel.connect(url, query_stash: { cache_store: MyCache.new, enabled: true })
DB.extension(:query_stash)
QueryStash::Sequel[DB].configure { |rules| rules.add_rule(...) }
```

The `query_stash` option takes `cache_store:` (required) and the other options of `QueryStash::Base#initialize`.

With [sequel-rails](https://rubygems.org/gems/sequel-rails) in the app, the railtie does the rest: the middleware, the jobs, and the database sequel-rails connected (`Sequel::Model.db`), all with the app's stash (`QueryStash::Sequel[Rails.application]`, configured by `config.query_stash`). Another database of the app only needs `OTHER_DB.extension(:query_stash)`, and gets the app's stash too.

### Mongo rules

Mongo rules match a selector built from the view: `collection_name`, `filter`, `limit`, `skip`, `sort`, `projection` and `pipeline`.

```ruby
QueryStash::Mongo[Rails.application].configure do |rules|
  rules.add_rule(
    {
      collection_name: "accounts",
      filter: { "token" => QueryStash::Mongo::ANY },
      limit: nil, skip: nil, sort: nil, projection: nil, pipeline: nil
    },
    name: "account_by_token",
    ttl_seconds: ->(result) { result.any? ? 10.minutes : 0 },
    ttl_jitter_seconds: 10
  )
end
```

Patterns:

| Pattern | Matches when |
|---|---|
| `QueryStash::Mongo::ANY` | the key is present, with any value |
| a Proc | `pattern.call(actual)` is truthy |
| a Regexp | `actual.to_s` matches |
| a Hash | every key in the pattern is present and matches; extra keys in the query are ignored |
| an Array | it is a prefix of the actual array, element by element |
| anything else | `actual == pattern`, so `limit: nil` excludes limited queries |

Hash patterns are subset matches: `filter: { "token" => ANY }` also matches `{ token: x, deleted_at: nil }`. Mongo queries are easy to cache by accident; test every rule against the queries your app actually sends.

Queries that match no rule stream through the driver untouched. Matching queries are loaded fully into memory so they can be cached, so don't write rules for large result sets.

A Mongo rule can be routed to its own store with `store:`.

### Stores

Set the store with `config.query_stash.cache_store`. It takes the same values as Rails' `config.cache_store`: a store name followed by its
arguments, or a store instance. The default is `[:memory_store, { size: 128.megabytes, compress: true }]`, one store per process. ActiveRecord and Mongo each build their own store from it, except from a store instance, which they share:

```ruby
# config/production.rb
config.query_stash.cache_store = :redis_cache_store, {
  url: ENV["STASH_REDIS_URL"],
  namespace: "query-stash:#{Rails.env}"
}

# or, shared by the processes on one machine:
config.query_stash.cache_store = :file_store, "tmp/query-stash"
```

- **MemoryStore**: one copy per process, no network hop. Keep `compress: true`; see the history for why.
- **Redis/Valkey**: shared across processes and hosts. If several environments share one cluster, put the environment in the namespace. The cache key doesn't include it, and two environments with the same database name would otherwise read each other's entries.
- **`file_store`**: Rails' own, shared by all processes on one machine. It has no LRU and no size cap, and nothing removes the entries that expired until `cleanup` is called on it, so size your rules so the directory can't fill the disk. ActiveRecord and Mongo would share the directory: give each its own with `config.query_stash.active_record.cache_store` and `config.query_stash.mongo.cache_store`.

### Options per adapter

`config.query_stash.active_record`, `config.query_stash.sequel` and `config.query_stash.mongo` (each one
exists when that framework is loaded) can set `enabled`, `isolated_state`,
`instrumenter`, `error_reporter` and `cache_store` for their adapter alone.
Whatever one of them doesn't set, it takes from `config.query_stash`, even if
that is set after it:

```ruby
# config/application.rb
config.query_stash.cache_store = :redis_cache_store, { url: ENV["STASH_REDIS_URL"] }
config.query_stash.mongo.cache_store = :memory_store, { size: 32.megabytes }
config.query_stash.active_record.enabled = false
```

Here ActiveRecord is only stashed inside `enable!` blocks, in the Redis store,
and Mongo is always stashed, in memory. An option that is set to `false` or
`nil` in a section counts as set. `raise_on_cache_error` is the same for both,
and read from `config.query_stash`.

They are read once, before `config/initializers` run, like the rest of
`config.query_stash`.

### Threads

What `enable!` and `disable!` set lives in `config.query_stash.isolated_state`, which is `ActiveSupport::IsolatedExecutionState` by default for Ruby on Rails, so threads spawned inside those blocks don't inherit it; they follow `config.query_stash.enabled` instead. Call `enable!` or `disable!` inside the thread to choose:

```ruby
Thread.new do
  QueryStash::ActiveRecord[Rails.application].enable! { Organization.find(id) }
end
```

Any object that responds to `[]`, `[]=`, `key?` and `delete` can be the isolated state, if your app keeps its per-request state somewhere else:

```ruby
config.query_stash.isolated_state = MyApp::CurrentContext
```

Without one, the stash keeps it in a thread variable: shared by the fibers of a thread, and not by other threads.

### Instrumentation

| Event | Payload |
|---|---|
| `cache_read.query_stash` | `adapter`, `rule`, `hit` |
| `cache_hit.query_stash` | `adapter`, `rule` |
| `cache_miss.query_stash` | `adapter`, `rule` |
| `cache_skip.query_stash` | `adapter`, `rule` |

A stash hit never reaches the adapter, so it fires no `sql.active_record` event. Subscribe to `cache_hit.query_stash` if you count queries per request.

`cache_miss.query_stash` fires when a result is about to be stored, and `cache_skip.query_stash` when its TTL says not to store it.

To run something for a specific rule, subscribe to the event and filter on the rule's name, which is in the payload:

```ruby
ActiveSupport::Notifications.subscribe("cache_hit.query_stash") do |event|
  next unless event.payload[:rule] == "published_template_by_id"

  StatsD.increment("query_stash.hit", tags: ["rule:#{event.payload[:rule]}"])
end
```

The events go to `config.query_stash.instrumenter`, which is `ActiveSupport::Notifications` by default. Any object with `instrument(name, payload) { |payload| ... }` works.

### Errors

Cache errors never fail the query: the read falls back to the database and a failed write is dropped. Errors go to `config.query_stash.error_reporter` (`ActiveSupport.error_reporter` by default; any object with `report(error, handled: true)` works), except in development and test, where they are raised. Set `config.query_stash.raise_on_cache_error` to change that.

## Without Rails

Outside of rails, you must set your application stash manually, from the options the railtie would otherwise
read from `config.query_stash`:

```ruby
QueryStash::ActiveRecord.set(
  app,
  QueryStash::ActiveRecord.new(
    cache_store: MyCache.new,  # required: any object with `read`, `write(key, value, expires_in:)` and `clear`
    enabled: true,
    isolated_state: MyApp::CurrentContext,  # `[]`, `[]=`, `key?` and `delete`; by default, a thread variable
    instrumenter: MyApp::Instrumenter,      # `instrument(name, payload) { ... }`; by default, no one
    error_reporter: MyApp::Errors,          # `report(error, handled: true)`; by default, a warning on stderr
    raise_on_cache_error: false
  )
)
```

### Write your own stash adapter

An adapter is a subclass of `QueryStash::Base` plus a patch of whatever runs its queries. The patch asks the
stash three things, in this order:

1. `rule_for(*args)`: the rule of the registry the query is stashed under, or `nil`, and then the query just runs.
2. `read(rule, *args)`: the stored result, or `nil`.
3. `write(rule, result, *args)`: stores the result, and returns it.

`*args` is whatever identifies a query to your adapter, and is the same for `read`, `write` and `cache_key_for`.
`rule_for` and `cache_key_for` are yours to define. `read` and `write` come from `QueryStash::Base`: they read and
write the cache store, emit the `cache_read`, `cache_hit`, `cache_miss` and `cache_skip` events
and handle cache errors, so override them only if you need something else. Results must never be `nil`,
since `nil` means a miss.

```ruby
class MyDriverStash < QueryStash::Base
  # `stashing?` is false when the stash is off.
  def rule_for(command)
    registry.match_rule(command.to_h) if stashing?
  end

  def cache_key_for(command)
    "v1:#{Digest::SHA256.hexdigest(command.to_json)}"
  end

  # The patch calls this in place of running the command.
  def wrap(command)
    rule = rule_for(command)
    return yield unless rule

    read(rule, command) || write(rule, yield, command)
  end
end

MyDriverStash.set(app, MyDriverStash.new(cache_store: MyCache.new))
MyDriverStash[app].enable! { ... }
```

Override `build_registry` to return a `QueryStash::Registry` subclass (`QueryStash::Registry::Sql` for rules that are regexps on SQL) if your rules need their own matching,
like the SQL and Mongo ones. The events carry the adapter's name, taken from the class name (`MyDriverStash` is
`:my_driver_stash`).

## Why this repo has history from before it existed

QueryStash ran in production as `ProcessQueryCache` inside Persona's Rails
monolith. When we extracted it, we did not start from one "initial commit."
We replayed the commits that shaped the library, each attributed to the
engineer who made the change, with Persona's internals removed.

Anyone can copy code now. What's hard to copy is why the code looks the way
it does, and that was learned in production:

- a TTL that never applied, because MemoryStore ignores `ttl:`
- a Rails upgrade that quietly routed every query around the patch
- spawned threads that bypassed the cache for months
- hand-rolled compression that left three copies of every blob on the heap
- a Mongo wrapper that turned streaming cursors into full loads and leaked
  memory on a large job
- a fix that was lost when a refactor merged over it

`git log --reverse` reads as the record of what broke and how it was fixed.
Some things to know when reading it:

- **Authors and dates.** Each replayed commit keeps its original author and
  author date. The committer is the person who replayed it, with the replay
  date. That's why the scaffold commit (October 2026) comes before commits
  authored in 2025.
- **Replay notes.** These explain where the gem had to differ from the
  original, for example a feature flag became a callable. Messages are the
  authors' own, edited only to remove internal details.
- **Scope.** Only commits that changed the library itself were replayed.
  Rule tuning, rollouts and app wiring stayed behind; what they taught is in
  the field notes below.
- **Bugs.** Bugs are replayed as they happened, so early commits contain
  bugs that later commits fix.
- **Naming.** The code was a "global query cache" in its first draft and
  `ProcessQueryCache` in production. It became QueryStash on extraction,
  because by then the store could be a file shared by every process on a
  machine, or a Redis cluster shared by every machine, and "process" no
  longer described it.

## Field notes

These are lessons from running it, mostly from changes to rules and app
wiring that aren't in this repo's history.

- **Start with immutable rows.** The first rule cached published template
  versions for a day and drafts not at all. Let the TTL callable decide from
  the result (@RickCSong, @ErnestChiu2023).
- **Don't cache "not found."** Return a TTL of 0 for empty results, or a
  lookup that runs before a row exists keeps missing it for the whole TTL
  (@4ndypanda, @RickCSong).
- **The TTL callable is a second allowlist.** One broad rule over a routing
  table cached only the class/key pairs its TTL lambda allowed, and skipped
  the rest (@RickCSong).
- **Avoid IN-list rules.** `WHERE id IN (...)` keys change with list
  membership on every request, so they churn the LRU with near-duplicate
  multi-megabyte entries. Look up rows one id at a time so they hit
  per-row entries (@4ndypanda, @HoneyryderChuck).
- **Size rules against real rows.** A rule over an 8 KiB-per-row table with
  hundreds of thousands of rows can't live in a 128MB MemoryStore. The file
  store has no size cap at all, so the same rule can fill a disk
  (@malavbhavsar).
- **The TTL on credential lookups bounds revocation.** A cached API key
  lookup keeps working until the TTL expires. Pick that TTL as a security
  decision, not a performance one; it was halved from an hour to 30 minutes
  (@cah6).
- **Turn it off where reads must see writes.** Low-traffic admin pages,
  dashboards, and jobs that read back what they just wrote all run
  `without_query_stash` (@RickCSong).
- **Big streaming jobs opt out.** Until queries without a matching rule
  stopped being buffered, one large job leaked memory fast. It was opted out
  first, then the root cause was fixed (@rpeng).
- **Workflow engines: wrap activities, not workflows.** Every database read
  happens inside an activity, so stashing there covers all of the query
  volume while keeping TTL-stale reads out of workflow decision code
  (@malavbhavsar).
- **Watch your Redis client wrapper across Rails upgrades.**
  `RedisCacheStore` changed how it builds connection pools in 7.1 (pass
  `pool: false` if you hand it a pool) and probes `wrapped_pool` in 8.1
  (@HoneyryderChuck, @segiddins).
- **Namespace shared stores by environment** (@ariel-ariel-liao,
  @jgandt-wp).
- **To debug a high miss rate, make the misses loud.** The file store
  swallowed its ENOENTs. Re-raising them for two days was a way to check
  whether they lined up with the misses (@HoneyryderChuck).

## Known issues

These are documented here and will be fixed after 0.1.0.

- A jitter of 0 still adds a fraction of a second, because `rand(0)` returns
  a Float.
- Mongo rules ignore `enabled:`.
- ActiveRecord rules ignore `store:`; only Mongo rules route per rule.
- Mongo aggregation views have no query filter; the selector's `filter` is
  `Enumerable#filter` there, so filter patterns don't apply to aggregations.
- The file store's background threads are never stopped.
- The file store measures its size with GNU `du -b`, so on macOS it reports
  0 and logs the error.

## Development

```sh
bin/setup
bundle exec rake      # specs + RuboCop
BUNDLE_GEMFILE=gemfiles/activerecord_7_2.gemfile bundle exec rspec
```

The specs boot a Rails app in `spec/dummy`. It uses an in-memory SQLite
database unless `DATABASE_URL` points somewhere else. The database is
created if it doesn't exist:

```sh
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/query_stash_test bundle exec rspec
DATABASE_URL=trilogy://root:mysql@127.0.0.1:3306/query_stash_test bundle exec rspec
DATABASE_URL=mongodb://127.0.0.1:27017/query_stash_test bundle exec rspec
```

Examples tagged `database: :active_record` or `database: :mongo` only run
against that kind of database.

### Types

The types are annotations in `lib/` ([rbs-inline](https://github.com/soutaro/rbs-inline)),
checked with [Steep](https://github.com/soutaro/steep), and exported to `sig/`
for the people who use the gem. Never edit `sig/` by hand:

```sh
bundle exec rbs collection init      # once: writes the (git-ignored) rbs_collection.yaml
bundle exec rbs collection install   # once: the types of the gems we call into
bundle exec rake sig:export          # lib/ annotations -> sig/
bundle exec rake types               # sig/ is up to date, and steep check passes
```

Every file in `lib/` is exported (`rbs-inline --opt-out`, which the Rake tasks use), so a new
file has signatures from the start, `untyped` ones until it is annotated. A file can opt out with
`# rbs_inline: disabled`.

CI runs the last one (`rake sig:verify`, then `steep check`), so a change to an
annotation has to come with the re-exported `sig/`.

- `sig_stubs/` has what neither the annotations nor the collection cover: a few
  parts of the Mongo driver and Rails.
- The Rails DSL in `lib/query_stash/railtie.rb` is not type checked
  (`# steep:ignore`): Rails runs those blocks with another `self`, and the
  collection has no types for them.
- Annotate with `#: (String) -> Integer` above a `def`. Multi-line types need
  `# @rbs param: Type` lines instead, and `Data.define` blocks are not read, so
  reopen the class to add methods (see `Registry::Rule`).

## License

Available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
