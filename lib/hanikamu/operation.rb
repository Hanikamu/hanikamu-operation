# frozen_string_literal: true

module Hanikamu
  # :nodoc:
  class Operation < Hanikamu::Service # rubocop:disable Metrics/ClassLength
    include ActiveModel::Validations

    class Error < Hanikamu::Service::Error; end

    # Error classes
    class FormError < Hanikamu::Service::Error
      attr_reader :form

      def initialize(form)
        @form = form
        super(form.is_a?(String) ? form : form.errors.full_messages.join(", "))
      end

      def errors
        return @form if @form.is_a?(String)

        @form.errors
      end
    end

    class GuardError < Hanikamu::Service::Error
      attr_reader :guard

      def initialize(guard)
        @guard = guard
        super(guard.is_a?(String) ? guard : guard.errors.full_messages.join(", "))
      end

      def errors
        return @guard if @guard.is_a?(String)

        @guard.errors
      end
    end

    class MissingBlockError < Hanikamu::Service::Error
    end

    class ConfigurationError < StandardError; end

    # Configuration
    setting :redis_client
    setting :mutex_expire_milliseconds, default: 1500
    setting :redlock_retry_count, default: 6
    setting :redlock_retry_delay, default: 500
    setting :redlock_retry_jitter, default: 50
    setting :redlock_timeout, default: 0.1
    setting :whitelisted_errors, default: [].freeze, constructor: ->(value) { Array(value) }

    # Override configure to cascade whitelisted_errors to Hanikamu::Service
    def self.configure
      super do |config|
        yield(config) if block_given?

        # Always include Redlock::LockError alongside user-provided errors
        whitelisted_errors = ([Redlock::LockError] + Array(config.whitelisted_errors)).uniq

        # Set on both Operation and Service configs because:
        # - Operation.config is checked when .call is invoked on Operation subclasses
        # - Service.config is set for consistency when directly calling Hanikamu::Service
        config.whitelisted_errors = whitelisted_errors
        Hanikamu::Service.config.whitelisted_errors = whitelisted_errors
      end
    end

    class << self
      def redis_lock
        @redis_lock ||= begin
          unless config.redis_client
            raise(
              ConfigurationError,
              "Hanikamu::Operation.config.redis_client is not configured. " \
              "Please set it in an initializer: Hanikamu::Operation.config.redis_client = your_redis_client"
            )
          end

          Redlock::Client.new(
            [config.redis_client],
            retry_count: config.redlock_retry_count,
            retry_delay: config.redlock_retry_delay,
            retry_jitter: config.redlock_retry_jitter,
            redis_timeout: config.redlock_timeout
          )
        end
      end

      # DSL methods
      def within_mutex(lock_key, expire_milliseconds: nil, if: nil, unless: nil)
        if_condition = binding.local_variable_get(:if)
        unless_condition = binding.local_variable_get(:unless)
        validate_mutex_conditions!(if_condition, unless_condition)

        @_mutex_lock_key = lock_key
        @_mutex_expire_milliseconds = expire_milliseconds || Hanikamu::Operation.config.mutex_expire_milliseconds
        @_mutex_if_condition = if_condition
        @_mutex_unless_condition = unless_condition
      end

      def within_transaction(klass)
        @_transaction_klass = klass
      end

      def block(bool)
        @_block = bool
      end

      # Define guard validations using a block
      # The block is evaluated in the context of a Guard class
      def guard(&block) # rubocop:disable Metrics/MethodLength
        return unless block

        # Thread-safe constant definition with mutex
        @guard_definition_mutex ||= Mutex.new
        @guard_definition_mutex.synchronize do
          # Remove existing Guard constant if it exists to support Rails reloading
          remove_const(:Guard) if const_defined?(:Guard, false)

          # Create a new Guard class with ActiveModel validations
          guard_class = Class.new do
            include ActiveModel::Validations

            attr_reader :operation
            alias service operation

            def initialize(operation)
              @operation = operation
            end

            # Helper to delegate methods to operation/service
            def self.delegates(*methods)
              methods.each do |method_name|
                define_method(method_name) do
                  operation.public_send(method_name)
                end
              end
            end

            class_eval(&block)
          end

          const_set(:Guard, guard_class)
        end
      end

      attr_reader :_mutex_lock_key, :_mutex_expire_milliseconds, :_mutex_if_condition, :_mutex_unless_condition,
                  :_transaction_klass, :_block

      private

      def validate_mutex_conditions!(if_condition, unless_condition)
        if if_condition && unless_condition
          raise ArgumentError, "Cannot specify both :if and :unless conditions for within_mutex"
        end

        if if_condition && !if_condition.respond_to?(:call)
          raise ArgumentError, "within_mutex :if condition must be a callable (e.g. a Proc or lambda)"
        end

        return unless unless_condition && !unless_condition.respond_to?(:call)

        raise ArgumentError, "within_mutex :unless condition must be a callable (e.g. a Proc or lambda)"
      end
    end

    def call!(&block)
      validate_block!(&block)

      within_mutex! do
        validate!
        guard!

        within_transaction! do
          block ? execute(&block) : execute
        end
      end
    end

    def validate_block!(&block)
      return unless self.class._block

      raise Hanikamu::Operation::MissingBlockError, "This service requires a block to be called" unless block
    end

    def within_mutex!(&)
      return yield if self.class._mutex_lock_key.blank?
      return yield unless _should_apply_mutex?

      # Snapshot the resolved key: it is documented as a String, and freezing a
      # copy prevents operation code from mutating the same object mid-run and
      # desyncing the reentrancy registry / lease bookkeeping (the cleanup would
      # otherwise look up a different value and leak the entry).
      lock_key = _stable_lock_key(public_send(self.class._mutex_lock_key))

      # Reentrancy: a nested operation invoked synchronously (e.g. from a synchronous
      # event handler, or a nested service call) while this context still holds this
      # exact key would otherwise re-acquire it. Redlock is not reentrant, so the same
      # execution context would block on itself until the TTL expires and then raise
      # Redlock::LockError. Skip the re-acquire and run inline; only real acquisitions
      # talk to Redis. Different fibers/threads/processes still contend normally.
      #
      # The bypass is gated on a *live* lease, not merely lexical nesting: we bypass
      # only while the innermost lease this context holds on the key is still valid.
      # Once it could have lapsed we fall through to a real acquire — which re-acquires
      # the key if it is free, or raises Redlock::LockError if it was taken over.
      return yield if _reentrant_lease_valid?(lock_key)

      _acquire_and_run(lock_key, &)
    end

    def within_transaction!(&)
      return yield if transaction_class.nil?

      transaction_class.transaction(&)
    end

    private

    def _should_apply_mutex?
      return false if self.class._mutex_if_condition && !instance_exec(&self.class._mutex_if_condition)
      return false if self.class._mutex_unless_condition && instance_exec(&self.class._mutex_unless_condition)

      true
    end

    # Acquire a real Redlock lease, push its deadline onto this context's stack for the
    # key, run, then release. Nested reentrant calls ride on this lease without touching
    # Redis; a nested call that finds the lease expired lands here again and takes a
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

    # A key is documented as a String; freeze a copy so it is a stable, immutable
    # registry key regardless of what the operation does with the original object.
    # Already-immutable values (frozen strings, symbols, integers) pass through.
    def _stable_lock_key(key)
      key.frozen? ? key : key.dup.freeze
    end

    # Per-key stack of monotonic deadlines (ms) for the real Redlock leases this context
    # currently holds, scoped to the current execution context. Storage is
    # `Thread.current[...]`, which in Ruby is fiber-local: this is the correct scope
    # because a synchronous event cascade or nested call runs in the same fiber as the
    # publishing operation, so it must be treated as the same holder. In the standard
    # thread-per-request / thread-per-job model (Puma, Sidekiq) each thread has a single
    # root fiber, so this is effectively per-thread. A separate job / request — or an
    # independently scheduled fiber under a fiber scheduler — has its own stack and must
    # still contend on Redis, which is exactly what we want (never bypass a lease held
    # elsewhere). A stack (not a single value) is required so that a replacement lease
    # taken after an outer lease expired restores the previous window when it exits.
    def _lease_stacks
      Thread.current[:hanikamu_operation_lease_stacks] ||= {}
    end

    def _monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    end

    # Bypass is valid only while the innermost lease this context holds on the key is
    # still within its lease window (the top of the stack is the most recently acquired,
    # hence longest-living, lease).
    def _reentrant_lease_valid?(lock_key)
      stack = _lease_stacks[lock_key]
      return false unless stack&.any?

      _monotonic_ms < stack.last
    end

    # Anchor the deadline to Redis's authoritative remaining TTL (already clock-drift
    # adjusted by Redlock), captured right after acquisition, so the window never
    # outlives the lease Redis actually granted — even if acquisition retried/took time.
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

    def transaction_class
      return if self.class._transaction_klass.nil?
      return ActiveRecord::Base if self.class._transaction_klass == :base

      self.class._transaction_klass
    end

    def validate!
      raise Hanikamu::Operation::FormError, self unless valid?
    end

    def guard!
      # Check for Guard constant defined directly on this class, not inherited
      return unless self.class.const_defined?(:Guard, false)

      # Always create a fresh guard instance for this specific operation
      # This prevents guard leakage when operations call other operations
      @guard = self.class.const_get(:Guard).new(self)
      raise_guard_error! unless @guard.valid?
    end

    def raise_guard_error!
      raise Hanikamu::Operation::GuardError, @guard
    end
  end
end
