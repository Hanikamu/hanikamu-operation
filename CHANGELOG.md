## [Unreleased]

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
