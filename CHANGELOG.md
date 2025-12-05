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
