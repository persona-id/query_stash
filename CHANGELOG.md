## [Unreleased]

## [0.1.0]

First release, extracted from Persona's `ProcessQueryCache`.

- Rule-allowlisted, cross-request caching of ActiveRecord `SELECT`s
  (`QueryStash::ActiveRecord`) and Mongo driver finds (`QueryStash::Mongo`),
  with per-rule TTL and jitter computed from the result.
- Any ActiveSupport cache store as the backend, including a file store
  shared by every process on a machine (`file_store`), and per-rule store
  routing for Mongo.
- `QueryStash::Rack::Middleware`, `with_query_stash` / `without_query_stash`,
  and a pluggable `QueryStash.state` for apps that propagate context into
  spawned threads.
- `cache_read.query_stash` and `cache_hit.query_stash` notifications.
- See the README for known issues.
