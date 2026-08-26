## [Unreleased]

## [0.4.0] - 2026-08-26

- Attribute failures are now raised as `Hanikamu::Operation::TypeError` instead of a bare
  `Dry::Struct::Error`. Dry::Struct names the offending attribute only inside its message, so it
  could not be rendered next to the field that caused it. `TypeError` exposes that attribute as
  `key` and through an `errors` ActiveModel::Errors object, matching the interface `FormError` and
  `GuardError` already provide.
- **Breaking Change**: `.call` now returns `Failure(Hanikamu::Operation::TypeError)` where it
  previously returned `Failure(Dry::Struct::Error)`, and `.call!` raises the former. Code that
  rescues or matches on `Dry::Struct::Error` for *this operation's own* arguments needs updating.
  A `Dry::Struct::Error` raised from anywhere else — inside `execute`, or by a nested struct —
  still propagates untouched.
- **Note**: `Hanikamu::Operation::TypeError` shadows Ruby's `::TypeError` inside operation
  subclasses, where a bare `TypeError` now resolves to this class through the ancestor chain.
  Reference `::TypeError` explicitly if you need Ruby's.

## [0.1.0] - 2025-11-26

- Initial release

## [0.1.1] - 2025-11-26

- Updated Gemfile.lock

## [0.1.2] - 2025-12-05

- **Breaking Change**: Minimum Ruby version is now 3.4.0
- Removed `redis-client` as direct dependency (now transitive through `redlock`)
- Updated CI to test only Ruby 3.4
- Improved README with clearer FormError vs GuardError examples

## [0.2.0] - 2026-03-10

- Added conditional locking for `within_mutex` via `:if` / `:unless` options: the Redis lock is
  skipped entirely when the condition opts out (e.g. an optional lock-key attribute is `nil`).
  Passing both `:if` and `:unless`, or a non-callable condition, raises `ArgumentError` at class
  definition time.

## [0.3.1] - 2026-08-26

- Fixed `RedisClient::NoScriptError: NOSCRIPT` raised on every `within_mutex` acquire when a host
  application runs its test suite with `Redlock::Client.testing_mode = :bypass` against a Redis with
  an empty script cache (typically a fresh CI container). 0.3.0 read the lease window with
  `get_remaining_ttl_for_resource`, which evaluates a Lua script; `:bypass` also stubs out Redlock's
  script loading, so the `EVALSHA` failed and Redlock's own recovery could not reload the script.
  The lease window is now taken from the `:validity` that Redlock already returns when the lock is
  acquired — no Lua script, and one fewer Redis round-trip per acquire. Lease-aware reentrancy
  behaviour is unchanged.

## [0.3.0] - 2026-08-25

- `within_mutex` is now reentrant within the same execution context (fiber-local, effectively
  per-thread in the standard thread-per-request / thread-per-job model): a nested acquire of a key
  the current context already holds runs inline instead of self-deadlocking. Only real acquisitions
  talk to Redis. The bypass is lease-aware — each real acquire records a deadline derived from
  Redis's own remaining TTL (clock-drift adjusted), and the inline bypass only applies while a lease
  this context holds is still live. Once the lease could have lapsed, a nested call re-acquires for
  real as its own lease (so deeper nested calls still bypass safely), or raises `Redlock::LockError`
  if the key was taken over. Cross-thread / cross-fiber / cross-process locking is unchanged.
  Reentrancy is the default with no opt-out flag.
