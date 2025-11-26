# frozen_string_literal: true

module Hanikamu
  # :nodoc:
  # rubocop:disable Metrics/ClassLength
  class Operation < Hanikamu::Service
    include ActiveModel::Validations

    Error = Class.new(Hanikamu::Service::Error)

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
      def within_mutex(lock_key, expire_milliseconds: nil)
        @_mutex_lock_key = lock_key
        @_mutex_expire_milliseconds = expire_milliseconds || Hanikamu::Operation.config.mutex_expire_milliseconds
      end

      def within_transaction(klass)
        @_transaction_klass = klass
      end

      def block(bool)
        @_block = bool
      end

      # Define guard validations using a block
      # The block is evaluated in the context of a Guard class
      # rubocop:disable Metrics/MethodLength
      def guard(&block)
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
      # rubocop:enable Metrics/MethodLength

      attr_reader :_mutex_lock_key, :_mutex_expire_milliseconds, :_transaction_klass, :_block
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
      return yield if _lock_key.nil?

      Hanikamu::Operation.redis_lock.lock!(_lock_key, self.class._mutex_expire_milliseconds, &)
    end

    def _lock_key
      return if self.class._mutex_lock_key.blank?

      public_send(self.class._mutex_lock_key)
    end

    def within_transaction!(&)
      return yield if transaction_class.nil?

      transaction_class.transaction(&)
    end

    private

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
  # rubocop:enable Metrics/ClassLength
end
