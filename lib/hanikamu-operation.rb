# frozen_string_literal: true

require "hanikamu/service"
require "active_model"
require "active_support/core_ext/object/blank"
require "redlock"

module Hanikamu
  # :nodoc:
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
      # Only check for Guard constant defined directly on this class, not inherited
      return unless self.class.const_defined?(:Guard, false)

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
