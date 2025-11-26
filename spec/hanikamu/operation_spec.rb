# frozen_string_literal: true

RSpec.describe Hanikamu::Operation do
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

    before do
      allow(described_class.redis_lock).to receive(:lock!).and_call_original
    end

    it "runs operation successfully" do
      expect(subject.successful).to be(true)
    end

    it "calls the redis lock with correct arguments" do
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

      it "raises a Redlock::LockError when called without a bang" do
        lock_info = described_class.redis_lock.lock(lock_key, 6000)

        expect { operation_with_mutex.call(lock_key: lock_key) }.to raise_error(Redlock::LockError)

        described_class.redis_lock.unlock(lock_info)
      end
    end

    context "when mutex is locked and released" do
      it "does not raise an error after lock expires" do
        lock_info = described_class.redis_lock.lock(lock_key, 500)
        sleep 1

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
end
