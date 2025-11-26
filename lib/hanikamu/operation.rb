# frozen_string_literal: true

module Hanikamu
  # :nodoc:
  class Operation < Hanikamu::Service
    include ActiveModel::Validations

    class FormError < Hanikamu::Service::Error
      attr_reader :form

      def initialize(form)
        @form = form
        super(form.is_a?(String) ? form : form.errors.full_messages.join(", "))
      end

      def errors
        form.errors
      end
    end

    class GuardError < Hanikamu::Service::Error
      attr_reader :guard

      def initialize(guard)
        @guard = guard
        super(guard.is_a?(String) ? guard : guard.errors.full_messages.join(", "))
      end

      def errors
        guard.errors
      end
    end

    class MissingBlockError < Hanikamu::Service::Error
    end

    class ConfigurationError < StandardError; end

    # Configuration class methods
    class << self
      attr_writer :redis_client, :mutex_expire_milliseconds, :redlock_retry_count,
                  :redlock_retry_delay, :redlock_retry_jitter, :redlock_timeout

      def redis_client
        @redis_client || raise(
          ConfigurationError,
          "Hanikamu::Operation.redis_client is not configured. " \
          "Please set it in an initializer: Hanikamu::Operation.redis_client = your_redis_client"
        )
      end

      def configure
        yield self
      end

      def mutex_expire_milliseconds
        @mutex_expire_milliseconds || 1500
      end

      def redlock_retry_count
        @redlock_retry_count || 6
      end

      def redlock_retry_delay
        @redlock_retry_delay || 500
      end

      def redlock_retry_jitter
        @redlock_retry_jitter || 50
      end

      def redlock_timeout
        @redlock_timeout || 0.1
      end

      def redis_lock
        @redis_lock ||= Redlock::Client.new(
          [redis_client],
          retry_count: redlock_retry_count,
          retry_delay: redlock_retry_delay,
          retry_jitter: redlock_retry_jitter,
          redis_timeout: redlock_timeout
        )
      end

      # DSL methods
      def within_mutex(lock_key, expire_milliseconds: nil)
        @_mutex_lock_key = lock_key
        @_mutex_expire_milliseconds = expire_milliseconds || Hanikamu::Operation.mutex_expire_milliseconds
      end

      def within_transaction(klass)
        @_transaction_klass = klass
      end

      def block(bool)
        @_block = bool
      end

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
      return yield if _trx_klass.nil?

      _trx_klass.transaction(&)
    end

    def _trx_klass
      return if self.class._transaction_klass.nil?

      self.class._transaction_klass == :base ? ActiveRecord::Base : self.class._transaction_klass
    end

    def validate!
      raise Hanikamu::Operation::FormError, self unless valid?
    end

    def guard!
      return unless self.class.const_defined?(:Guard)

      raise_guard_error! unless guard.valid?
    end

    def guard
      @guard ||= self.class.const_get(:Guard).new(self)
    end

    def raise_guard_error!
      raise Hanikamu::Operation::GuardError, guard
    end
  end
end
