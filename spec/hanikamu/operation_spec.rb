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
    it "creates separate Guard constants for each operation class with independent validations" do # rubocop:disable RSpec/MultipleExpectations
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

    it "maintains separate guard validations for different operations regardless of execution context" do # rubocop:disable RSpec/ExampleLength
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

    it "maintains guard isolation during concurrent execution of different operation classes" do
      results = []
      threads = []
      mutex = Mutex.new

      # Create two different operation classes
      5.times do
        threads << Thread.new do
          result = TestFail.call(id: "B") # Should succeed
          mutex.synchronize { results << { class: "TestFail", success: result.success? } }
        end

        threads << Thread.new do
          result = TestPass.call(id: "A", name: "Valid") # Should succeed
          mutex.synchronize { results << { class: "TestPass", success: result.success? } }
        end
      end

      threads.each(&:join)

      # All operations should have succeeded
      expect(results.count { |r| r[:success] }).to eq(10)

      # Should have executed both operation types
      expect(results.count { |r| r[:class] == "TestFail" }).to eq(5)
      expect(results.count { |r| r[:class] == "TestPass" }).to eq(5)
    end

    it "does not mix error messages from different operation guards" do # rubocop:disable RSpec/ExampleLength
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

    it "maintains guard isolation when operations call other operations (Rails Event Store pattern)" do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
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

    it "maintains thread safety when simulating Sidekiq concurrent job execution" do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
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

    # Unit tests will stub lock locally; integration tests use real Redis

    it "runs operation successfully" do
      allow(described_class.redis_lock).to receive(:lock).and_call_original
      expect(subject.successful).to be(true)
    end

    it "calls the redis lock with correct arguments" do
      allow(described_class.redis_lock).to receive(:lock).and_call_original
      subject

      expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 1500)
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
        allow(described_class.redis_lock).to receive(:lock).and_call_original
        subject

        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 500)
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

    context "with :if condition" do
      let(:operation_with_if) do
        Class.new(Hanikamu::Operation) do
          attribute :order_id?, Types::Params::Integer.optional

          within_mutex(:mutex_lock, if: -> { !order_id.nil? })

          def execute
            response(successful: true)
          end

          def mutex_lock
            "Order$#{order_id}"
          end

          define_singleton_method(:name) { "RSpecOperationWithIfCondition" }
        end
      end

      it "acquires the lock when the :if condition is truthy" do
        allow(described_class.redis_lock).to receive(:lock).and_call_original
        result = operation_with_if.call!(order_id: 42)

        expect(result.successful).to be(true)
        expect(described_class.redis_lock).to have_received(:lock).with("Order$42", 1500)
      end

      it "skips the lock when the :if condition is falsy" do
        allow(described_class.redis_lock).to receive(:lock).and_call_original
        result = operation_with_if.call!(order_id: nil)

        expect(result.successful).to be(true)
        expect(described_class.redis_lock).not_to have_received(:lock)
      end

      it "does not call the lock key method when the condition skips" do
        expect_any_instance_of(operation_with_if).not_to receive(:mutex_lock) # rubocop:disable RSpec/AnyInstance
        operation_with_if.call!(order_id: nil)
      end
    end

    context "with :unless condition" do
      let(:operation_with_unless) do
        Class.new(Hanikamu::Operation) do
          attribute :order_id?, Types::Params::Integer.optional

          within_mutex(:mutex_lock, unless: -> { order_id.nil? })

          def execute
            response(successful: true)
          end

          def mutex_lock
            "Order$#{order_id}"
          end

          define_singleton_method(:name) { "RSpecOperationWithUnlessCondition" }
        end
      end

      it "acquires the lock when the :unless condition is falsy" do
        allow(described_class.redis_lock).to receive(:lock).and_call_original
        result = operation_with_unless.call!(order_id: 42)

        expect(result.successful).to be(true)
        expect(described_class.redis_lock).to have_received(:lock).with("Order$42", 1500)
      end

      it "skips the lock when the :unless condition is truthy" do
        allow(described_class.redis_lock).to receive(:lock).and_call_original
        result = operation_with_unless.call!(order_id: nil)

        expect(result.successful).to be(true)
        expect(described_class.redis_lock).not_to have_received(:lock)
      end
    end

    context "with no condition" do
      it "always acquires the lock (backward-compatible)" do
        allow(described_class.redis_lock).to receive(:lock).and_call_original
        subject

        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 1500)
      end
    end

    context "with a non-callable :if condition" do
      it "raises ArgumentError at class definition time" do
        expect do
          Class.new(Hanikamu::Operation) do
            within_mutex(:mutex_lock, if: true)
          end
        end.to raise_error(ArgumentError, /must be a callable/)
      end
    end

    context "with a non-callable :unless condition" do
      it "raises ArgumentError at class definition time" do
        expect do
          Class.new(Hanikamu::Operation) do
            within_mutex(:mutex_lock, unless: "not a proc")
          end
        end.to raise_error(ArgumentError, /must be a callable/)
      end
    end

    context "with both :if and :unless" do
      it "raises ArgumentError at class definition time" do
        expect do
          Class.new(Hanikamu::Operation) do
            within_mutex(:mutex_lock, if: -> { true }, unless: -> { false })
          end
        end.to raise_error(ArgumentError, /Cannot specify both :if and :unless/)
      end
    end

    context "when reentrant (the same execution context already holds the key)" do
      after do
        Thread.current[:hanikamu_operation_lease_stacks] = nil
      end

      let(:effects) { [] }

      # Acquires its lock, signals the current context's held-lease depth via
      # `entered`, then blocks on `release` so the caller can hold the lock open while a
      # second thread tries to acquire the same key. The TTL is set well above the
      # Redlock retry window (~3s) so the lock does not expire out from under the
      # contending thread mid-retry.
      def build_blocking(entered, release)
        Class.new(Hanikamu::Operation) do
          attribute :lock_key, Types::String
          within_mutex(:mutex_lock, expire_milliseconds: 6000)

          define_method(:execute) do
            entered << Thread.current[:hanikamu_operation_lease_stacks][lock_key].size
            release.pop
            response(ok: true)
          end

          define_method(:mutex_lock) { lock_key }
          define_singleton_method(:name) { "RSpecBlockingReentrantOp" }
        end
      end

      def build_inner(effects, should_raise: false)
        Class.new(Hanikamu::Operation) do
          attribute :lock_key, Types::String
          within_mutex(:mutex_lock)

          define_method(:execute) do
            effects << :inner_ran
            raise "inner boom" if should_raise

            response(inner: true)
          end

          define_method(:mutex_lock) { lock_key }
          define_singleton_method(:name) { "RSpecInnerReentrantOp" }
        end
      end

      def build_outer(effects, inner_klass, inner_lock_key:)
        Class.new(Hanikamu::Operation) do
          attribute :lock_key, Types::String
          within_mutex(:mutex_lock)

          define_method(:execute) do
            effects << :outer_ran
            inner_klass.call!(lock_key: inner_lock_key)
            response(outer: true)
          end

          define_method(:mutex_lock) { lock_key }
          define_singleton_method(:name) { "RSpecOuterReentrantOp" }
        end
      end

      it "acquires the Redis lock only once for nested same-key operations and runs both" do
        inner = build_inner(effects)
        outer = build_outer(effects, inner, inner_lock_key: lock_key)
        allow(described_class.redis_lock).to receive(:lock).and_call_original

        result = outer.call!(lock_key: lock_key)

        expect(result.outer).to be(true)
        expect(effects).to eq(%i[outer_ran inner_ran])
        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 1500).once
      end

      it "acquires the Redis lock only once for deeply nested same-key operations" do
        inner = build_inner(effects)
        middle = build_outer(effects, inner, inner_lock_key: lock_key)
        outer = build_outer(effects, middle, inner_lock_key: lock_key)
        allow(described_class.redis_lock).to receive(:lock).and_call_original

        outer.call!(lock_key: lock_key)

        expect(effects).to eq(%i[outer_ran outer_ran inner_ran])
        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 1500).once
      end

      it "preserves the inner operation's return value on the reentrant path" do
        inner = build_inner(effects)
        outer = Class.new(Hanikamu::Operation) do
          attribute :lock_key, Types::String
          within_mutex(:mutex_lock)

          define_method(:execute) { inner.call!(lock_key: lock_key) }
          define_method(:mutex_lock) { lock_key }
          define_singleton_method(:name) { "RSpecOuterReturningInner" }
        end

        result = outer.call!(lock_key: lock_key)

        expect(result.inner).to be(true)
      end

      it "acquires the Redis lock for each key when nested operations use different keys" do
        inner_lock_key = SecureRandom.uuid
        inner = build_inner(effects)
        outer = build_outer(effects, inner, inner_lock_key: inner_lock_key)
        allow(described_class.redis_lock).to receive(:lock).and_call_original

        outer.call!(lock_key: lock_key)

        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 1500)
        expect(described_class.redis_lock).to have_received(:lock).with(inner_lock_key, 1500)
      end

      it "does not share the lease stack across threads and still contends on Redis" do
        entered = Queue.new
        release = Queue.new
        blocking = build_blocking(entered, release)

        holder = Thread.new { blocking.call!(lock_key: lock_key) }
        begin
          # The holder is now inside execute with its own lease stack populated.
          expect(entered.pop).to eq(1)

          # A second thread must NOT see the holder's lease stack (proving the stack
          # is per-context, not global) and must contend on Redis instead.
          error = nil
          Thread.new do
            operation_with_mutex.call!(lock_key: lock_key)
          rescue StandardError => e
            error = e
          end.join

          expect(error).to be_a(Redlock::LockError)
        ensure
          release << :go
          holder.join
        end
      end

      it "leaves no lease-stack leak after a nested run completes" do
        inner = build_inner(effects)
        outer = build_outer(effects, inner, inner_lock_key: lock_key)

        outer.call!(lock_key: lock_key)

        expect(Thread.current[:hanikamu_operation_lease_stacks]).to be_empty
      end

      it "leaves no lease-stack leak after a nested run raises inside the inner block" do
        inner = build_inner(effects, should_raise: true)
        outer = build_outer(effects, inner, inner_lock_key: lock_key)

        expect { outer.call!(lock_key: lock_key) }.to raise_error("inner boom")

        expect(Thread.current[:hanikamu_operation_lease_stacks]).to be_empty
      end

      it "re-acquires a nested same-key call once the outer lease has expired instead of bypassing" do
        inner = build_inner(effects)
        outer = Class.new(Hanikamu::Operation) do
          attribute :lock_key, Types::String
          within_mutex(:mutex_lock, expire_milliseconds: 100)

          define_method(:execute) do
            sleep 0.25 # let this operation's own 100ms lease lapse
            inner.call!(lock_key: lock_key)
            response(ok: true)
          end

          define_method(:mutex_lock) { lock_key }
          define_singleton_method(:name) { "RSpecExpiryOuterOp" }
        end
        allow(described_class.redis_lock).to receive(:lock).and_call_original

        outer.call!(lock_key: lock_key)

        # Outer acquired for real (ttl 100); after expiry the nested call must NOT
        # bypass but re-acquire for real (inner's default ttl 1500).
        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 100).once
        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 1500).once
      end

      it "lets a deeper same-key call bypass a replacement lease taken after the outer lease expired" do
        inner = build_inner(effects)
        middle = build_outer(effects, inner, inner_lock_key: lock_key)
        # NOTE: unlike `build_outer`, this outer op records nothing in `effects` —
        # only middle (:outer_ran) and inner (:inner_ran) do.
        outer = Class.new(Hanikamu::Operation) do
          attribute :lock_key, Types::String
          within_mutex(:mutex_lock, expire_milliseconds: 100)

          define_method(:execute) do
            sleep 0.25 # let this operation's own 100ms lease lapse
            middle.call!(lock_key: lock_key)
            response(ok: true)
          end

          define_method(:mutex_lock) { lock_key }
          define_singleton_method(:name) { "RSpecExpiryDeepOuterOp" }
        end
        allow(described_class.redis_lock).to receive(:lock).and_call_original

        result = outer.call!(lock_key: lock_key)

        # Outer's 100ms lease lapsed, so `middle` takes a fresh real lease (ttl 1500);
        # `inner` then rides that replacement lease inline instead of contending with it
        # (the self-deadlock this stack-based bookkeeping guards against). Both run.
        expect(result.ok).to be(true)
        expect(effects).to eq(%i[outer_ran inner_ran])
        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 100).once
        expect(described_class.redis_lock).to have_received(:lock).with(lock_key, 1500).once
      end

      it "cleans up the lease stack even when the lock-key string is mutated during execute" do
        op = Class.new(Hanikamu::Operation) do
          within_mutex(:mutex_lock)

          define_method(:execute) do
            mutex_lock << "-mutated" # mutate the same String object the registry saw
            response(ok: true)
          end

          def mutex_lock
            @mutex_lock ||= "MutableKey$#{object_id}"
          end

          define_singleton_method(:name) { "RSpecMutableKeyOp" }
        end

        expect { op.call! }.not_to raise_error
        expect(Thread.current[:hanikamu_operation_lease_stacks]).to be_empty
      end

      # Downstream test suites commonly stub Redlock out with `testing_mode = :bypass`,
      # which also no-ops Redlock's `load_scripts`. On a cold Redis (a fresh CI
      # container with an empty script cache) any EVALSHA then fails with NOSCRIPT and
      # Redlock's own self-heal cannot recover, because reloading is exactly what
      # :bypass disabled. The mutex path must therefore never evaluate a Lua script.
      context "with Redlock's :bypass testing mode and a cold Redis script cache" do
        around do |example|
          Redlock::Client.testing_mode = :bypass
          example.run
        ensure
          Redlock::Client.testing_mode = nil
        end

        before { described_class.config.redis_client.call("SCRIPT", "FLUSH") }

        it "acquires and re-enters without evaluating a Lua script" do
          inner = build_inner(effects)
          outer = build_outer(effects, inner, inner_lock_key: lock_key)

          expect { outer.call!(lock_key: lock_key) }.not_to raise_error
          expect(effects).to eq(%i[outer_ran inner_ran])
        end
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

  describe "attribute type errors" do
    let(:typed_operation) do
      Class.new(Hanikamu::Operation) do
        attribute :name, Types::String
        attribute :age, Types::Integer

        def execute
          response(successful: true)
        end

        define_singleton_method(:name) { "RSpecTypedOperation" }
      end
    end

    # Dry::Struct failures are raised, not returned, so capture the error to inspect it.
    def attribute_error_from
      yield
      nil
    rescue Hanikamu::Operation::AttributeError => e
      e
    end

    context "when a required attribute is missing" do
      it "raises an AttributeError rather than a bare Dry::Struct::Error" do
        expect { typed_operation.call!(age: 30) }.to raise_error(Hanikamu::Operation::AttributeError)
      end

      it "exposes the missing attribute as the error key" do
        expect(attribute_error_from { typed_operation.call!(age: 30) }.key).to eq(:name)
      end

      it "files the failure under that attribute in an ActiveModel errors object" do
        error = attribute_error_from { typed_operation.call!(age: 30) }

        expect(error.errors[:name]).to eq([":name is missing in Hash input"])
      end

      it "reports the missing attribute when called with no arguments at all" do
        expect(attribute_error_from { typed_operation.call! }.key).to eq(:name)
      end
    end

    context "when an attribute has the wrong type" do
      it "exposes the offending attribute as the error key" do
        error = attribute_error_from { typed_operation.call!(name: "Ada", age: "not-a-number") }

        expect(error.key).to eq(:age)
      end

      it "keeps Dry's explanation of the type violation in the message" do
        error = attribute_error_from { typed_operation.call!(name: "Ada", age: "not-a-number") }

        expect(error.message).to include("has invalid type for :age")
      end
    end

    it "returns a Failure carrying the AttributeError when called without a bang" do
      result = typed_operation.call(age: 30)

      expect(result.failure).to be_a(Hanikamu::Operation::AttributeError)
    end

    it "still runs normally when the attributes are valid" do
      expect(typed_operation.call!(name: "Ada", age: 30).successful).to be(true)
    end

    context "when a Dry::Struct::Error originates somewhere other than this operation's schema" do
      it "propagates the original error instead of misattributing it to an attribute" do
        operation = Class.new(Hanikamu::Operation) do
          attribute :name, Types::String

          define_method(:execute) { raise Dry::Struct::Error, "raised from execute" }
          define_singleton_method(:name) { "RSpecInnerRaisingOperation" }
        end

        expect { operation.call!(name: "Ada") }.to raise_error(Dry::Struct::Error, "raised from execute")
      end

      it "propagates the original error when the input is not even a Hash" do
        expect { typed_operation.call!("not-a-hash") }.to raise_error(Dry::Struct::Error)
      end
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

    describe Hanikamu::Operation::AttributeError do
      context "when initialized with a schema error carrying a key" do
        subject { described_class.new(schema_error) }

        let(:schema_error) { Dry::Types::MissingKeyError.new(:email) }

        it "exposes the offending attribute as the key" do
          expect(subject.key).to eq(:email)
        end

        it "keeps the underlying schema message" do
          expect(subject.message).to eq(schema_error.message)
        end

        it "files the failure under that attribute in an ActiveModel errors object" do
          expect(subject.errors[:email]).to eq([schema_error.message])
        end

        it "builds full messages from the attribute name" do
          expect(subject.errors.full_messages).to eq(["Email :email is missing in Hash input"])
        end

        it "inherits from Hanikamu::Service::Error" do
          expect(subject).to be_a(Hanikamu::Service::Error)
        end
      end

      context "when initialized with a message" do
        subject { described_class.new(error_message) }

        let(:error_message) { "something went wrong" }

        it "returns the correct error message" do
          expect(subject.message).to eq(error_message)
        end

        it "falls back to :base as the key" do
          expect(subject.key).to eq(:base)
        end

        it "files the failure under :base" do
          expect(subject.errors[:base]).to eq([error_message])
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
