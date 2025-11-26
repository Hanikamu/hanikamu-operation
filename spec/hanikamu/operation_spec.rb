# frozen_string_literal: true

RSpec.describe Hanikamu::Operation do
  class TestFail < Hanikamu::Operation
    attribute :id, Types::String

    guard do
      delegates :id
      validates :id, exclusion: { in: ["A"], message: "cannot be A" }
    end

    def execute
      "this fails when string is A"
    end
  end

  class TestPass < Hanikamu::Operation
    attribute :id, Types::String
    attribute :name, Types::String.optional

    guard do
      delegates :name, :id
      validates :name, presence: true
    end

    def execute
      "this does not fail when string is A"
    end
  end

  it "verifies TestFail and TestPass have independent guard validations" do
    expect { TestFail.call!(id: "A") }.to raise_error(Hanikamu::Operation::GuardError)
    expect { TestPass.call!(id: "A", name: "Valid Name") }.not_to raise_error
  end

  describe "guard isolation between operation classes" do
    # rubocop:disable RSpec/MultipleExpectations
    it "creates separate Guard constants for each operation class with independent validations" do
      # TestFail should have its own Guard with the :id exclusion validation
      expect(TestFail.const_defined?(:Guard, false)).to be(true)

      # TestPass should have its own Guard with the :name presence validation
      expect(TestPass.const_defined?(:Guard, false)).to be(true)

      # The Guard classes should be different objects
      expect(TestFail.const_get(:Guard)).not_to eq(TestPass.const_get(:Guard))

      # Verify they have independent validations by calling the operations
      # TestFail should fail with id "A"
      expect { TestFail.call!(id: "A") }.to raise_error(Hanikamu::Operation::GuardError, /cannot be A/)

      # TestFail should succeed with id "B"
      result = TestFail.call(id: "B")
      expect(result).to be_success

      # TestPass should fail without a name
      expect { TestPass.call!(id: "A", name: nil) }.to raise_error(Hanikamu::Operation::GuardError, /can't be blank/)

      # TestPass should succeed with a name
      result = TestPass.call(id: "A", name: "Valid")
      expect(result).to be_success
    end
    # rubocop:enable RSpec/MultipleExpectations

    # rubocop:disable RSpec/ExampleLength
    it "maintains separate guard validations for different operations regardless of execution context" do
      module TestModule
        class TransactionOp1 < Hanikamu::Operation
          attribute :id, Types::String

          guard do
            delegates :id
            validates :id, exclusion: { in: ["forbidden1"], message: "cannot be forbidden1" }
          end

          def execute
            response(value: "op1_success")
          end
        end

        class TransactionOp2 < Hanikamu::Operation
          attribute :id, Types::String

          guard do
            delegates :id
            validates :id, exclusion: { in: ["forbidden2"], message: "cannot be forbidden2" }
          end

          def execute
            response(value: "op2_success")
          end
        end
      end

      # Both operations should have different guards
      expect(TestModule::TransactionOp1.const_get(:Guard)).not_to eq(TestModule::TransactionOp2.const_get(:Guard))

      # Operation1 should fail with "forbidden1" but succeed with "forbidden2"
      expect do
        TestModule::TransactionOp1.call!(id: "forbidden1")
      end.to raise_error(Hanikamu::Operation::GuardError, /forbidden1/)
      result1 = TestModule::TransactionOp1.call!(id: "forbidden2")
      expect(result1.value).to eq("op1_success")

      # Operation2 should have opposite behavior
      expect do
        TestModule::TransactionOp2.call!(id: "forbidden2")
      end.to raise_error(Hanikamu::Operation::GuardError, /forbidden2/)
      result2 = TestModule::TransactionOp2.call!(id: "forbidden1")
      expect(result2.value).to eq("op2_success")
    end
    # rubocop:enable RSpec/ExampleLength

    it "maintains guard isolation during concurrent execution of different operation classes" do
      results = []
      threads = []

      # Create two different operation classes
      5.times do
        threads << Thread.new do
          result = TestFail.call(id: "B") # Should succeed
          results << { class: "TestFail", success: result.success? }
        end

        threads << Thread.new do
          result = TestPass.call(id: "A", name: "Valid") # Should succeed
          results << { class: "TestPass", success: result.success? }
        end
      end

      threads.each(&:join)

      # All operations should have succeeded
      expect(results.count { |r| r[:success] }).to eq(10)

      # Should have executed both operation types
      expect(results.count { |r| r[:class] == "TestFail" }).to eq(5)
      expect(results.count { |r| r[:class] == "TestPass" }).to eq(5)
    end

    # rubocop:disable RSpec/ExampleLength
    it "does not mix error messages from different operation guards" do
      # Create two operations with different guard validations
      module TestModule
        class PortfolioOp < Hanikamu::Operation
          attribute :state, Types::String

          guard do
            delegates :state
            validates :state,
                      inclusion: { in: ["ready_to_onboard"],
                                   message: "Portfolio onboarding state skal være ready_to_onboard" }
          end

          def execute
            response(success: true)
          end
        end

        class UserOp < Hanikamu::Operation
          attribute :state, Types::String

          guard do
            delegates :state
            validates :state,
                      inclusion: { in: ["ready_to_onboard"],
                                   message: "User onboarding state skal være ready_to_onboard" }
          end

          def execute
            response(success: true)
          end
        end
      end

      # Call PortfolioOp with invalid state - should only have Portfolio error
      begin
        TestModule::PortfolioOp.call!(state: "invalid")
        raise "Expected GuardError to be raised"
      rescue Hanikamu::Operation::GuardError => e
        expect(e.message).to include("Portfolio onboarding state")
        expect(e.message).not_to include("User onboarding state")
      end

      # Call UserOp with invalid state - should only have User error
      begin
        TestModule::UserOp.call!(state: "invalid")
        raise "Expected GuardError to be raised"
      rescue Hanikamu::Operation::GuardError => e
        expect(e.message).to include("User onboarding state")
        expect(e.message).not_to include("Portfolio onboarding state")
      end
    end
    # rubocop:enable RSpec/ExampleLength

    # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    it "maintains guard isolation when operations call other operations (Rails Event Store pattern)" do
      # Simulate Rails Event Store / event handler pattern where operations call other operations
      module TestModule
        class PortfolioOnboardingOp < Hanikamu::Operation
          attribute :portfolio_state, Types::String

          guard do
            delegates :portfolio_state
            validates :portfolio_state,
                      inclusion: { in: ["ready_to_onboard"],
                                   message: "Portfolio onboarding state skal være ready_to_onboard" }
          end

          def execute
            # This operation calls another operation in its execute method
            UserOnboardingOp.call!(user_state: "ready_to_onboard")
            response(success: true, message: "Portfolio onboarded")
          end
        end

        class UserOnboardingOp < Hanikamu::Operation
          attribute :user_state, Types::String

          guard do
            delegates :user_state
            validates :user_state,
                      inclusion: { in: ["ready_to_onboard"],
                                   message: "User onboarding state skal være ready_to_onboard" }
          end

          def execute
            response(success: true, message: "User onboarded")
          end
        end
      end

      # When Portfolio operation calls User operation, guards should remain isolated
      # Portfolio with valid state, User with valid state - both should succeed
      result = TestModule::PortfolioOnboardingOp.call!(portfolio_state: "ready_to_onboard")
      expect(result.success).to be(true)
      expect(result.message).to eq("Portfolio onboarded")

      # Portfolio with invalid state should fail with only Portfolio error
      begin
        TestModule::PortfolioOnboardingOp.call!(portfolio_state: "invalid")
        raise "Expected GuardError to be raised"
      rescue Hanikamu::Operation::GuardError => e
        expect(e.message).to include("Portfolio onboarding state")
        expect(e.message).not_to include("User onboarding state")
      end

      # User with invalid state should fail with only User error
      begin
        TestModule::UserOnboardingOp.call!(user_state: "invalid")
        raise "Expected GuardError to be raised"
      rescue Hanikamu::Operation::GuardError => e
        expect(e.message).to include("User onboarding state")
        expect(e.message).not_to include("Portfolio onboarding state")
      end

      # Edge case: Portfolio valid but it calls User with invalid state
      # This should fail with User error, not Portfolio error
      module TestModule
        class PortfolioOpCallingInvalidUser < Hanikamu::Operation
          attribute :portfolio_state, Types::String

          guard do
            delegates :portfolio_state
            validates :portfolio_state,
                      inclusion: { in: ["ready_to_onboard"],
                                   message: "Portfolio onboarding state skal være ready_to_onboard" }
          end

          def execute
            # Intentionally call UserOnboardingOp with invalid state
            UserOnboardingOp.call!(user_state: "invalid")
            response(success: true, message: "This should not be reached")
          end
        end
      end

      begin
        TestModule::PortfolioOpCallingInvalidUser.call!(portfolio_state: "ready_to_onboard")
        raise "Expected GuardError to be raised from nested UserOnboardingOp"
      rescue Hanikamu::Operation::GuardError => e
        # Should have User error, not Portfolio error
        expect(e.message).to include("User onboarding state")
        expect(e.message).not_to include("Portfolio onboarding state")
      end
    end
    # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

    # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    it "maintains thread safety when simulating Sidekiq concurrent job execution" do
      # Simulate a Sidekiq job operation
      module TestModule
        class ProcessPaymentJob < Hanikamu::Operation
          attribute :order_id, Types::Integer
          attribute :amount, Types::Float

          guard do
            delegates :order_id, :amount
            validates :order_id, presence: true
            validates :amount, numericality: { greater_than: 0 }
          end

          def execute
            # Simulate some processing work
            sleep(rand * 0.01) # Random tiny delay to increase chance of race conditions
            response(
              success: true,
              order_id: order_id,
              amount: amount,
              thread_id: Thread.current.object_id
            )
          end
        end

        class SendEmailJob < Hanikamu::Operation
          attribute :user_id, Types::Integer
          attribute :template, Types::String

          guard do
            delegates :user_id, :template
            validates :user_id, presence: true
            validates :template, inclusion: { in: %w[welcome confirmation], message: "must be welcome or confirmation" }
          end

          def execute
            # Simulate some processing work
            sleep(rand * 0.01) # Random tiny delay to increase chance of race conditions
            response(
              success: true,
              user_id: user_id,
              template: template,
              thread_id: Thread.current.object_id
            )
          end
        end
      end

      results = []
      threads = []
      mutex = Mutex.new

      # Simulate 20 concurrent Sidekiq workers processing different jobs
      10.times do |i|
        # Payment job thread
        threads << Thread.new do
          result = TestModule::ProcessPaymentJob.call!(order_id: i + 1, amount: 100.0 + i)
          mutex.synchronize { results << { type: "payment", result: result } }
        end

        # Email job thread
        threads << Thread.new do
          result = TestModule::SendEmailJob.call!(user_id: i + 1, template: "welcome")
          mutex.synchronize { results << { type: "email", result: result } }
        end
      end

      # Wait for all threads to complete
      threads.each(&:join)

      # Verify all jobs completed successfully
      expect(results.size).to eq(20)
      expect(results.all? { |r| r[:result].success }).to be(true)

      # Verify each job type has correct results
      payment_results = results.select { |r| r[:type] == "payment" }
      email_results = results.select { |r| r[:type] == "email" }

      expect(payment_results.size).to eq(10)
      expect(email_results.size).to eq(10)

      # Verify no guard leakage - each job should have validated only its own attributes
      payment_results.each do |r|
        expect(r[:result].order_id).to be_a(Integer)
        expect(r[:result].amount).to be_a(Float)
        expect(r[:result]).not_to respond_to(:user_id)
        expect(r[:result]).not_to respond_to(:template)
      end

      email_results.each do |r|
        expect(r[:result].user_id).to be_a(Integer)
        expect(r[:result].template).to eq("welcome")
        expect(r[:result]).not_to respond_to(:order_id)
        expect(r[:result]).not_to respond_to(:amount)
      end

      # Verify guard validations still work correctly for invalid data
      # Test negative amount (passes dry-types but fails guard)
      expect do
        TestModule::ProcessPaymentJob.call!(order_id: 1, amount: -10.0)
      end.to raise_error(Hanikamu::Operation::GuardError, /must be greater than 0/)

      # Test zero amount (passes dry-types but fails guard)
      expect do
        TestModule::ProcessPaymentJob.call!(order_id: 1, amount: 0.0)
      end.to raise_error(Hanikamu::Operation::GuardError, /must be greater than 0/)

      # Test invalid template (passes dry-types but fails guard)
      expect do
        TestModule::SendEmailJob.call!(user_id: 1, template: "invalid")
      end.to raise_error(Hanikamu::Operation::GuardError, /must be welcome or confirmation/)
    end
    # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
  end

  describe "#within_mutex" do
    subject { operation_with_mutex.call!(lock_key: lock_key) }

    let(:lock_key) { SecureRandom.uuid }
    let(:operation_with_mutex) do
      Class.new(Hanikamu::Operation) do
        attribute :lock_key, Types::String

        within_mutex(:mutex_lock)

        def execute
          response(successful: true)
        end

        def mutex_lock
          lock_key
        end

        define_singleton_method(:name) { "RSpecOperationWithMutex" }
      end
    end

    # Unit tests will stub lock! locally; integration tests use real Redis

    it "runs operation successfully" do
      allow(described_class.redis_lock).to receive(:lock!).and_call_original
      expect(subject.successful).to be(true)
    end

    it "calls the redis lock with correct arguments" do
      allow(described_class.redis_lock).to receive(:lock!).and_call_original
      subject

      expect(described_class.redis_lock).to have_received(:lock!).with(lock_key, 1500)
    end

    context "with custom expire_milliseconds" do
      let(:operation_with_mutex) do
        Class.new(Hanikamu::Operation) do
          attribute :lock_key, Types::String

          within_mutex(:mutex_lock, expire_milliseconds: 500)

          def execute
            response(successful: true)
          end

          def mutex_lock
            lock_key
          end

          define_singleton_method(:name) { "RSpecOperationWithCustomExpiry" }
        end
      end

      it "calls the redis lock with custom expire_milliseconds" do
        allow(described_class.redis_lock).to receive(:lock!).and_call_original
        subject

        expect(described_class.redis_lock).to have_received(:lock!).with(lock_key, 500)
      end
    end

    context "when mutex is locked" do
      it "raises a Redlock::LockError when called with a bang" do
        lock_info = described_class.redis_lock.lock(lock_key, 6000)

        expect { subject }.to raise_error(Redlock::LockError)

        described_class.redis_lock.unlock(lock_info)
      end

      it "returns a Failure with Redlock::LockError when called without a bang" do
        lock_info = described_class.redis_lock.lock(lock_key, 6000)

        result = operation_with_mutex.call(lock_key: lock_key)
        expect(result).to be_failure
        expect(result.failure).to be_a(Redlock::LockError)

        described_class.redis_lock.unlock(lock_info)
      end
    end

    context "when mutex is locked and released" do
      it "does not raise an error after lock expires" do
        lock_info = described_class.redis_lock.lock(lock_key, 1000)
        # Wait for the lock to expire
        wait_until?(timeout: 2) do
          info = described_class.redis_lock.lock(lock_key, 1000)
          described_class.redis_lock.unlock(info) if info
          !info.nil?
        rescue Redlock::LockAcquisitionError
          false
        end

        expect { subject }.not_to raise_error

        described_class.redis_lock.unlock(lock_info)
      end
    end
  end

  describe "#within_transaction" do
    let(:mock_model) { double("ActiveRecord::Base") }
    let(:operation_with_transaction) do
      captured_model = mock_model
      Class.new(Hanikamu::Operation) do
        within_transaction(captured_model)

        def execute
          response(successful: true)
        end

        define_singleton_method(:name) { "RSpecOperationWithTransaction" }
      end
    end

    it "wraps execution in a transaction" do
      expect(mock_model).to receive(:transaction).and_yield

      operation_with_transaction.call!
    end
  end

  describe "validations" do
    let(:operation_with_validations) do
      Class.new(Hanikamu::Operation) do
        attribute :email, Types::String.optional

        validates :email, presence: true

        def execute
          response(successful: true)
        end

        define_singleton_method(:name) { "RSpecOperationWithValidations" }
      end
    end

    it "raises FormError when invalid" do
      expect { operation_with_validations.call!(email: nil) }.to raise_error(Hanikamu::Operation::FormError)
    end

    it "includes error messages in the exception" do

      operation_with_validations.call!(email: nil)
    rescue Hanikamu::Operation::FormError => e
      expect(e.message).to include("Email can't be blank")
      expect(e.errors).to be_present

    end
  end

  describe "guard" do
    let(:operation_with_guard) do
      module TestModule
        class GuardedOp < Hanikamu::Operation
          attribute :value, Types::Integer

          class Guard
            include ActiveModel::Validations

            attr_reader :operation

            def initialize(operation)
              @operation = operation
            end

            validate :value_must_be_positive

            def value_must_be_positive
              errors.add(:value, "must be positive") if operation.value <= 0
            end
          end

          def execute
            response(successful: true)
          end
        end
      end
      TestModule::GuardedOp
    end

    it "raises GuardError when guard is invalid" do
      expect { operation_with_guard.call!(value: -1) }.to raise_error(Hanikamu::Operation::GuardError)
    end

    it "executes successfully when guard is valid" do
      result = operation_with_guard.call!(value: 10)
      expect(result.successful).to be(true)
    end

    it "includes error messages in the exception" do

      operation_with_guard.call!(value: 0)
    rescue Hanikamu::Operation::GuardError => e
      expect(e.message).to include("must be positive")
      expect(e.errors).to be_present

    end

    it "can delegate to service attributes" do
      module TestModule
        class DelegateGuardOp < Hanikamu::Operation
          attribute :portfolio_id, Types::Integer.optional
          attribute :state, Types::String.optional

          guard do
            delegates :portfolio_id, :state
            validates :portfolio_id, presence: true
            validate :check_state

            def check_state
              errors.add(:state, "must be active") if state && state != "active"
            end
          end

          def execute
            response(successful: true)
          end
        end
      end

      expect { TestModule::DelegateGuardOp.call!(portfolio_id: nil, state: "active") }.to raise_error(Hanikamu::Operation::GuardError)
      expect { TestModule::DelegateGuardOp.call!(portfolio_id: 123, state: "inactive") }.to raise_error(Hanikamu::Operation::GuardError)
      result = TestModule::DelegateGuardOp.call!(portfolio_id: 123, state: "active")
      expect(result.successful).to be(true)
    end
  end

  describe "#block" do
    let(:operation_requiring_block) do
      module TestModule
        class BlockOp < Hanikamu::Operation
          block true

          def execute
            yield
            response(successful: true)
          end
        end
      end
      TestModule::BlockOp
    end

    it "raises MissingBlockError when block is not provided" do
      expect { operation_requiring_block.call! }.to raise_error(Hanikamu::Operation::MissingBlockError)
    end

    it "executes successfully when block is provided" do
      result = operation_requiring_block.call! { "block executed" }
      expect(result.successful).to be(true)
    end
  end

  describe "Errors" do
    describe Hanikamu::Operation::GuardError do
      let(:error_message) { "Whoooa, somethings wrong!" }

      context "when initialized with a string" do
        subject { described_class.new(error_message) }

        it "sets the guard attribute to the input string" do
          expect(subject.guard).to eq(error_message)
        end

        it "returns the correct error message" do
          expect(subject.message).to eq(error_message)
        end

        it "returns the string when calling errors" do
          expect(subject.errors).to eq(error_message)
        end
      end

      context "when initialized with a guard object" do
        subject do
          guard.valid?
          described_class.new(guard)
        end

        let(:defined_guard) do
          Class.new do
            include ActiveModel::Validations

            attr_reader :operation

            def initialize(operation)
              @operation = operation
            end

            validates :string_value, presence: true

            def string_value
              operation.string_value
            end

            define_singleton_method(:name) { "RSpecTestingGuardErrorDefinedGuard" }
          end
        end

        let(:defined_operation) do
          Struct.new(:string_value) do
            define_singleton_method(:name) { "RSpecTestingGuardErrorDefinedOperation" }
          end
        end

        let(:operation_instance) { defined_operation.new("") }
        let(:guard) { defined_guard.new(operation_instance) }

        it "returns the concatenated validation messages" do
          expect(subject.message).to include("String value can't be blank")
        end

        it "sets the guard attribute to the input guard object" do
          expect(subject.guard).to eq(guard)
        end

        it "returns the guard's errors object" do
          expect(subject.errors).to eq(guard.errors)
        end
      end
    end

    describe Hanikamu::Operation::FormError do
      let(:error_message) { "Whoooa, somethings wrong!" }

      context "when initialized with a string" do
        subject { described_class.new(error_message) }

        it "sets the form attribute to the input string" do
          expect(subject.form).to eq(error_message)
        end

        it "returns the correct error message" do
          expect(subject.message).to eq(error_message)
        end

        it "returns the string when calling errors" do
          expect(subject.errors).to eq(error_message)
        end
      end

      context "when initialized with a form object" do
        subject do
          form.valid?
          described_class.new(form)
        end

        let(:defined_form) do
          Class.new do
            include ActiveModel::Validations

            attr_accessor :string_value

            validates :string_value, presence: true

            def initialize(string_value:)
              @string_value = string_value
            end

            define_singleton_method(:name) { "RSpecTestingFormErrorDefinedForm" }
          end
        end

        let(:form) { defined_form.new(string_value: "") }

        it "returns the concatenated validation messages" do
          expect(subject.message).to include("String value can't be blank")
        end

        it "sets the form attribute to the input form object" do
          expect(subject.form).to eq(form)
        end

        it "returns the form's errors object" do
          expect(subject.errors).to eq(form.errors)
        end
      end
    end

    describe Hanikamu::Operation::MissingBlockError do
      let(:error_message) { "This operation requires a block" }

      context "when initialized with a message" do
        subject { described_class.new(error_message) }

        it "returns the correct error message" do
          expect(subject.message).to eq(error_message)
        end

        it "inherits from Hanikamu::Service::Error" do
          expect(subject).to be_a(Hanikamu::Service::Error)
        end
      end
    end

    describe Hanikamu::Operation::ConfigurationError do
      let(:error_message) { "Redis client not configured" }

      context "when initialized with a message" do
        subject { described_class.new(error_message) }

        it "returns the correct error message" do
          expect(subject.message).to eq(error_message)
        end

        it "inherits from StandardError" do
          expect(subject).to be_a(StandardError)
        end
      end
    end
  end

  describe "configuration" do
    describe "whitelisted_errors" do
      it "always includes Redlock::LockError by default" do
        described_class.configure { |_config| } # rubocop:disable Lint/EmptyBlock
        expect(Hanikamu::Service.config.whitelisted_errors).to include(Redlock::LockError)
      end

      it "propagates whitelisted_errors alongside Redlock::LockError" do
        custom_error = Class.new(StandardError)

        described_class.configure do |config|
          config.whitelisted_errors = [custom_error]
        end

        expect(Hanikamu::Service.config.whitelisted_errors).to include(Redlock::LockError)
        expect(Hanikamu::Service.config.whitelisted_errors).to include(custom_error)
      end

      it "deduplicates errors when Redlock::LockError is explicitly added" do
        described_class.configure do |config|
          config.whitelisted_errors = [Redlock::LockError, StandardError]
        end

        redlock_count = Hanikamu::Service.config.whitelisted_errors.count(Redlock::LockError)
        expect(redlock_count).to eq(1)
      end
    end
  end
end
