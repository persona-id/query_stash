# QueryStash

Cross-request query result caching for ActiveRecord and MongoDB, for the
handful of hot, slow-changing lookups you choose.

Rails' query cache lives for one request. QueryStash keeps the result of an
allowlisted query across requests and jobs, for a TTL you compute from the
result itself, in an ActiveSupport cache store of your choosing. It hooks
the database adapter (and the Mongo driver), so call sites don't change:
`Organization.find(id)` is served from the stash when a rule matches it.

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

It ran in production at [Persona](https://withpersona.com) as
`ProcessQueryCache` from October 2025 before it was extracted into this gem.

## When to use it, and when not to

Use it for point lookups that are read far more often than they change, and
where a bounded amount of staleness is acceptable: tenants, plans, API key
lookups, published (immutable) versions of things.

Know what it does not do:

- **No invalidation.** Entries leave on TTL (plus jitter) or eviction. A
  write does not clear the stash, so a read after a write can return the
  old row until the TTL runs out. Wrap read-after-write code in
  `disable!`, or don't stash those queries.
- **Inlined SQL only.** Queries with bind parameters are passed through
  untouched. Use an adapter or configuration that inlines values (Trilogy
  and mysql2 do by default; set `prepared_statements: false` for SQLite or
  PostgreSQL).
- **`SELECT` only**, matched with `/\ASELECT/i`. SQL that starts with a
  comment, whitespace or a `WITH` clause is never stashed.
- **Not transaction-aware.** A matching read inside a transaction can be
  served from the stash instead of seeing the transaction's own writes.
- **`load_async` queries bypass it.**
- The ActiveRecord cache key is the SQL plus `ActiveRecord::Base.current_shard`.
  It does not include the role or the database name.

## Installation

```sh
bundle add query_stash
```

The railtie loads the adapter for each framework your app uses, ActiveRecord
and Mongoid, when that framework loads.

ActiveRecord 7.2, 8.0 and 8.1 and Ruby 3.3 through 4.0 are tested in CI,
against SQLite, PostgreSQL, MySQL and MongoDB (through Mongoid). The Mongo
adapter targets the 2.19 driver.

## Usage

### Turning it on and off

`config.query_stash.enabled` (true by default) decides whether queries are
stashed. With the default, every query that matches a rule is stashed,
including in the console, rake tasks and migrations.

`enable!` and `disable!` override it for the duration of a block. The
railtie wraps every request in `enable!` (through
`QueryStash::ActiveRecord::Middleware` and `QueryStash::Mongo::Middleware`,
one for each framework your app uses) and every ActiveJob `perform`. So
with `enabled = false`, only requests and jobs are stashed:

```ruby
# config/application.rb
config.query_stash.enabled = false
```

Wrap jobs from other job systems however they allow:

```ruby
QueryStash::ActiveRecord[Rails.application].enable! do
  QueryStash::Mongo[Rails.application].enable! { run_job }
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

The railtie builds a `QueryStash::ActiveRecord` and a `QueryStash::Mongo`
for the app from `config.query_stash`, before `config/initializers` run.
Configure their rules from an initializer.

Rules match the SQL with a `Regexp`, first match wins:

```ruby
QueryStash::ActiveRecord[Rails.application].configure do |rules|
  rules.add_rule(
    /\ASELECT "templates"\.\* FROM "templates" WHERE "templates"\."id" = /,
    name: "published_template_by_id",
    ttl_seconds: ->(result) { result.to_a.all? { |row| row["status"] == "published" } ? 1.day : 0 },
    ttl_jitter_seconds: 1.hour,
    on_cache_hit: ->(rule, _result) { StatsD.increment("query_stash.hit", tags: ["rule:#{rule.name}"]) },
    on_cache_miss: ->(rule, _result) { StatsD.increment("query_stash.miss", tags: ["rule:#{rule.name}"]) },
    on_cache_skip: ->(rule, _result) { StatsD.increment("query_stash.skip", tags: ["rule:#{rule.name}"]) },
    enabled: -> { Flipper.enabled?(:stash_templates) }
  )
end
```

- `ttl_seconds` and `ttl_jitter_seconds` are integers or callables that
  receive the uncached result. A TTL of 0 or less means "don't cache this
  result" (a *skip*). Entries are written with
  `expires_in: ttl_seconds + rand(ttl_jitter_seconds)`, so entries for a hot
  rule don't all expire at once.
- `on_cache_hit`, `on_cache_miss` and `on_cache_skip` receive the rule and
  the result. A miss fires just before the write.
- `enabled` turns a single rule off without removing it.

### Mongo rules

Mongo rules match a selector built from the view: `collection_name`,
`filter`, `limit`, `skip`, `sort`, `projection` and `pipeline`.

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

Hash patterns are subset matches: `filter: { "token" => ANY }` also matches
`{ token: x, deleted_at: nil }`. Mongo queries are easy to cache by
accident; test every rule against the queries your app actually sends.

Queries that match no rule stream through the driver untouched. Matching
queries are loaded fully into memory so they can be cached, so don't write
rules for large result sets.

A Mongo rule can be routed to its own store with `store:`.

### Stores

Set the store with `config.query_stash.cache_store`. It takes the same
values as Rails' `config.cache_store`: a store name followed by its
arguments, or a store instance. The default is
`[:memory_store, { size: 128.megabytes, compress: true }]`, one store per
process. ActiveRecord and Mongo each build their own store from it, except
from a store instance, which they share:

```ruby
# config/application.rb
config.query_stash.cache_store = :redis_cache_store, {
  url: ENV["STASH_REDIS_URL"],
  namespace: "query-stash:#{Rails.env}"
}

# or, shared by the processes on one machine:
config.query_stash.cache_store = :file_store, "tmp/query-stash"
```

`:file_store` builds a `QueryStash::FileStore`, with the adapter's prefix on
the directory's basename: the example above stores ActiveRecord results in
`tmp/active-record-query-stash` and Mongo results in `tmp/mongo-query-stash`.
Each one locks a file next to its directory (`tmp/active-record-query-stash.lock`)
while it cleans up.

- **MemoryStore**: one copy per process, no network hop. Keep
  `compress: true`; see the history for why.
- **Redis/Valkey**: shared across processes and hosts. If several
  environments share one cluster, put the environment in the namespace. The
  cache key doesn't include it, and two environments with the same database
  name would otherwise read each other's entries.
- **`file_store`**: shared by all processes on one machine. A background
  thread runs `cleanup` every 5 minutes, because FileStore has no LRU and no
  size cap. Size your rules so the directory can't fill the disk.

`QueryStash::ActiveRecord[Rails.application].cache_usage_bytes` (and the
same on `QueryStash::Mongo`) reports the size of the store (Redis
`used_memory`, refreshed at most once a minute; the file store's own
measurement; or the MemoryStore's size).

### Threads

What `enable!` and `disable!` set lives in
`ActiveSupport::IsolatedExecutionState`, so threads spawned inside those
blocks don't inherit it; they follow `config.query_stash.enabled` instead.
Call `enable!` or `disable!` inside the thread to choose:

```ruby
Thread.new do
  QueryStash::ActiveRecord[Rails.application].enable! { Organization.find(id) }
end
```

### Instrumentation

| Event | Payload |
|---|---|
| `cache_read.query_stash` | `adapter`, `rule`, `hit` |
| `cache_hit.query_stash` (ActiveRecord) | `adapter`, `rule` |

A stash hit never reaches the adapter, so it fires no `sql.active_record`
event. Subscribe to `cache_hit.query_stash` if you count queries per
request.

### Errors

Cache errors never fail the query: the read falls back to the database and
a failed write is dropped. Errors go to `ActiveSupport.error_reporter`,
except in development and test, where they are raised. Set
`config.query_stash.raise_on_cache_error` to change that.

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

- **The ActiveRecord patch can miss adapters that load late.** The adapter
  patch is prepended into the adapter classes that are already loaded when
  `ActiveRecord::Base` loads. In a standard Rails boot the database adapter
  usually loads later, on first connection. The stash then does nothing,
  silently. Until this is fixed, prepend it from your adapter's load hook:

  ```ruby
  # config/initializers/query_stash.rb
  ActiveSupport.on_load(:active_record_trilogyadapter) do # or _mysql2adapter, _postgresqladapter, _sqlite3adapter
    prepend QueryStash::ActiveRecord::AdapterPatch
  end
  ```

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

## License

Available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
