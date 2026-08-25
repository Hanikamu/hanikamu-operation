# Make `within_mutex` reentrant in `hanikamu-operation`

**Status:** implemented; pending release
**Owner:** Nicolai
**Repo touched:** `hanikamu-operation`

---

## TL;DR

`Hanikamu::Operation`'s `within_mutex` uses a **non-reentrant** Redlock. When an operation
that holds a lock key synchronously triggers another operation that locks the **same** key —
via a synchronous event handler, or a plain nested service/operation call — the second acquire
blocks on a lock the same thread already holds. It spins for the retry window and then raises
`Redlock::LockError`. This is a **latent self-deadlock**, and it becomes a hard, reproducible
failure as soon as the mutex TTL is long enough that the outer lock hasn't expired by the time
the inner acquire runs.

The sustainable fix is to make `within_mutex` **reentrant per execution context** (fiber-local,
effectively per-thread in the standard thread-per-request / thread-per-job model): if the current context
already holds the resolved lock key, run inline instead of re-acquiring; only the outermost holder
talks to Redis. This is the default behaviour — **no opt-in flag** (see "Design decision").

---

## Why this happens

- A distributed lock keyed by some resource is re-entered by the **same execution context** within
  one logical unit of work (a synchronous callback cascade, or a nested operation call), but Redlock
  treats that re-entry as a competing writer.
- Redlock is not reentrant, so the inner acquire waits on the outer's lock. It exhausts the retry
  window and raises `Redlock::LockError` — with **no concurrent request** anywhere.
- Raising the mutex TTL doesn't create the bug; it turns a race that was formerly "usually survived
  by lock expiry" into a hard, deterministic failure.

### The nesting shapes that trigger it

1. **Synchronous callback cascade.** An operation holds `Resource$id` and publishes an event; a
   **synchronous** handler for that event invokes another operation whose lock key is also
   `Resource$id`.
2. **Nested service/operation call.** An operation holds `Resource$id` and, inside `execute`, calls
   another operation (directly or via a service) that locks the same `Resource$id`.

Asynchronous callbacks (handlers that run in a separate job/thread) are never the problem — they run
outside the publisher's mutex and contend on Redis normally.

---

## The fix (in `hanikamu-operation`)

Only `#within_mutex!` changes, plus a small thread-local registry. File: `lib/hanikamu/operation.rb`.

### Before

```ruby
def within_mutex!(&)
  return yield if self.class._mutex_lock_key.blank?
  return yield unless _should_apply_mutex?

  lock_key = public_send(self.class._mutex_lock_key)
  Hanikamu::Operation.redis_lock.lock!(lock_key, self.class._mutex_expire_milliseconds, &)
end
```

### After (reentrant)

```ruby
def within_mutex!(&)
  return yield if self.class._mutex_lock_key.blank?
  return yield unless _should_apply_mutex?

  # Freeze a copy so operation code can't mutate the key object and desync the registry.
  lock_key = _stable_lock_key(public_send(self.class._mutex_lock_key))

  # Reentrancy: a synchronous nested call while this context still holds a *live* lease
  # on the key would otherwise re-acquire it and self-deadlock (Redlock is not
  # reentrant). Run inline instead — but only while a lease this context holds is still
  # valid (see below). Once it could have lapsed, fall through to a real acquire so a
  # taken-over key still raises Redlock::LockError.
  return yield if _reentrant_lease_valid?(lock_key)

  _acquire_and_run(lock_key, &)
end
```

Add to the `private` section (see `lib/hanikamu/operation.rb` for the full set):

```ruby
# Real acquire: push this lease's deadline onto this context's per-key stack, run,
# then pop. A nested call that finds the lease expired lands here again and takes a
# fresh, independent lease (its own stack frame), so it never contends with itself.
def _acquire_and_run(lock_key, &)
  Hanikamu::Operation.redis_lock.lock!(lock_key, self.class._mutex_expire_milliseconds) do
    _push_lease(lock_key)
    begin
      yield
    ensure
      _pop_lease(lock_key)
    end
  end
end

def _stable_lock_key(key)
  key.frozen? ? key : key.dup.freeze
end

# Fiber-local per-key stack of live-lease deadlines (Thread.current[...] is
# fiber-local): correct scope because a synchronous cascade runs in the same fiber; a
# separate job/request/fiber has its own stack and contends. A stack (not a single
# value) lets a replacement lease taken after expiry restore the previous window when
# it exits.
def _lease_stacks
  Thread.current[:hanikamu_operation_lease_stacks] ||= {}
end

def _monotonic_ms
  Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
end

# Bypass only while the innermost (top) lease this context holds is still live.
def _reentrant_lease_valid?(lock_key)
  stack = _lease_stacks[lock_key]
  return false unless stack&.any?

  _monotonic_ms < stack.last
end

# Anchor the deadline to Redis's authoritative remaining TTL (already clock-drift
# adjusted by Redlock), captured right after acquisition, so the window never outlives
# the lease Redis actually granted — even if acquisition retried/took time.
def _push_lease(lock_key)
  remaining = Hanikamu::Operation.redis_lock.get_remaining_ttl_for_resource(lock_key)
  deadline = _monotonic_ms + (remaining || self.class._mutex_expire_milliseconds)
  (_lease_stacks[lock_key] ||= []) << deadline
end

def _pop_lease(lock_key)
  stack = _lease_stacks[lock_key]
  return unless stack

  stack.pop
  _lease_stacks.delete(lock_key) if stack.empty?
end
```

### Why this is correct / safe

- **Return value preserved:** `redis_lock.lock!` returns the block's value; `_acquire_and_run`
  returns the value of `yield` (the `ensure` around `_pop_lease` doesn't override it), and the bypass
  path is a plain `yield`. Operation responses flow through unchanged.
- **Exception-safe:** a lease is only pushed once we're inside the `lock!` block, and the `ensure`
  always pops it. If `lock!` itself fails to acquire (real contention from another context), the
  block never runs, so nothing is pushed and nothing leaks.
- **Lease-aware, not merely lexical:** the bypass is gated on a live lease — each real acquire pushes
  a deadline derived from Redis's own remaining TTL (already clock-drift adjusted), captured right
  after acquisition, so the window never outlives the lease Redis granted (even under a slow/retried
  acquire). If an operation outlives its mutex TTL, a nested same-key call re-acquires for real as
  its own stack frame instead of running inline — re-locking a free key (deeper nested calls then
  bypass *that* replacement lease, avoiding a fresh self-deadlock) or raising `Redlock::LockError` on
  takeover. Reentrancy never weakens mutual exclusion beyond Redlock's inherent TTL guarantee.
- **Stable key:** the key is snapshotted (frozen copy) before use, so an operation mutating the
  original String object can't leak a stack entry or make a future call wrongly bypass Redis.
- **Distributed guarantee intact:** reentrancy is strictly same-context (same fiber) and only while
  the lease is valid. Cross-thread / cross-fiber / cross-process contention is unchanged — a lock
  held by a *different* context still raises `Redlock::LockError`.
- **No behaviour change for non-nesting code:** first acquire hits Redis and releases at the end,
  exactly as today.
- **TTL:** nested reentrant calls don't refresh the TTL — same as today for any single long op.

---

## Design decision: default, not configurable

Reentrancy is the **default** with **no opt-out flag**. Rationale:

- A same-context re-acquire of a held key has **no valid non-reentrant use case** — it can only
  self-deadlock then raise. Nobody opts into that.
- Matches `Monitor`, Java `ReentrantLock`, and ActiveRecord nested transactions (savepoints).
- Adding `within_mutex(:key, reentrant: false)` would only re-expose the footgun and add config
  surface (violates the repo's Simplicity-First rule). If an escape hatch is ever genuinely needed,
  put it at config level (`config.reentrant_mutex`, default `true`) — not per declaration.

---

## Specs to add (`spec/hanikamu/operation_spec.rb`, `#within_mutex` describe block)

The suite already uses a **real Redis** (`described_class.redis_lock`). Cover:

1. **Nested, same key, same context → single Redis acquire, both run.**
   Define an outer op whose `execute` calls an inner op with the **same** lock key. Spy on
   `redis_lock.lock!` and assert it received the key **once**, and both ops ran (in order).
2. **Nested, different keys → two acquires.** Outer op calls inner op with a **different** key;
   assert `lock!` received both keys.
3. **Cross-thread still contends.** Run an outer op that acquires the key and blocks inside `execute`
   with its lease stack populated; a second thread calling the same key does **not** see the stack
   and raises `Redlock::LockError`.
4. **Stack cleanup (success).** After a nested run completes,
   `Thread.current[:hanikamu_operation_lease_stacks]` is empty — no leak.
5. **Stack cleanup (raise).** After a nested run that raises inside the inner block, the stack is
   still empty — the `ensure` pops on the exception path.
6. **Lease expiry → re-acquire.** An outer op with a short TTL that sleeps past its lease, then makes
   a nested same-key call, must **re-acquire** (a second `lock!` for the key), not bypass.
7. **Deep nesting after expiry (no self-deadlock).** An outer op whose short lease lapses calls a
   middle op (same key) that re-acquires a fresh lease, which calls an inner op (same key): the inner
   call must **bypass** the replacement lease inline and complete — proving the per-key stack tracks
   the live replacement lease, not the expired outer deadline.
8. **Mutable key snapshot.** An op whose lock-key method returns a String that `execute` mutates
   still cleans up the stack (no leaked entry under the pre-mutation value).

---

## Release

1. Implement the change + specs above.
2. Bump `spec.version` `0.2.0 → 0.3.0` in the gemspec.
3. CHANGELOG `## [0.3.0]`: *"`within_mutex` is now reentrant within the same execution context
   (fiber-local, effectively per-thread): a nested acquire of a key the current context already holds
   runs inline instead of self-deadlocking. Cross-thread / cross-fiber / cross-process locking is
   unchanged."*
4. Document the reentrancy behaviour in the README `within_mutex` section.
5. Run gem `rspec` + `rubocop`, release (MFA required per rubygems).

---

## Verification

- `make rspec` — the new reentrancy specs pass, and the existing `#within_mutex` specs
  (single-acquire, `:if`/`:unless`, cross-thread `Redlock::LockError`) still pass unchanged.
- `make cops` — clean.
- Any downstream app that was working around this by namespacing lock keys for nested operations can
  drop the workaround: locking the bare resource key from nested operations is now safe.
