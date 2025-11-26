# Hanikamu::Operation

[![ci](https://github.com/Hanikamu/hanikamu-operation/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-operation/actions/workflows/ci.yml)

A Ruby gem that extends [hanikamu-service](https://github.com/Hanikamu/hanikamu-service) with advanced operation patterns including distributed locking, database transactions, form validations, and guard conditions. Perfect for building robust, concurrent-safe business operations in Rails applications.

## Philosophy

`hanikamu-operation` builds upon the service object pattern established by `hanikamu-service`, adding critical infrastructure concerns that complex business operations require:

### Core Principles from hanikamu-service

- **Single Responsibility**: Each operation encapsulates one business transaction
- **Type Safety**: Input validation via dry-struct type checking
- **Monadic Error Handling**: `.call` returns `Success` or `Failure` monads; `.call!` raises exceptions
- **Clean Architecture**: Business logic isolated from models and controllers
- **Predictable Interface**: All operations follow the same `.call` / `.call!` pattern

### Extended Operation Capabilities

Building on this foundation, `hanikamu-operation` adds:

- **Distributed Locking**: Prevent race conditions across multiple processes/servers using Redis locks (Redlock algorithm)
- **Database Transactions**: Wrap operations in ActiveRecord transactions with automatic rollback
- **Form Validations**: ActiveModel validations on the operation itself
- **Guard Conditions**: Pre-execution business rule validation (e.g., permissions, state checks)
- **Block Requirements**: Enforce callback patterns for operations that need them

### When to Use

Use `Hanikamu::Operation` (instead of plain `Hanikamu::Service`) when your business logic requires:

- **Concurrency Control**: Multiple users/processes might execute the same operation simultaneously
- **Transactional Integrity**: Multiple database changes must succeed/fail atomically
- **Complex Validation**: Both input validation AND business rule validation
- **State Guards**: Pre-conditions that determine if the operation can proceed
- **Critical Sections**: Code that must not be interrupted or run concurrently

## Installation

Add to your application's Gemfile:

```ruby
gem 'hanikamu-operation', '~> 0.1.0'
```

Then execute:

```bash
bundle install
```

## Setup

### 1. Configure Redis Client

Create an initializer `config/initializers/hanikamu_operation.rb`:

```ruby
# frozen_string_literal: true

require 'redis-client'

# Required: Redis client for distributed locking
Hanikamu::Operation.config.redis_client = RedisClient.new(
  url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
  reconnect_attempts: 3,
  timeout: 1.0
)

# Optional: Customize Redlock settings (these are the defaults)
Hanikamu::Operation.config.mutex_expire_milliseconds = 1500  # Lock TTL
Hanikamu::Operation.config.redlock_retry_count = 6           # Number of retry attempts
Hanikamu::Operation.config.redlock_retry_delay = 500         # Milliseconds between retries
Hanikamu::Operation.config.redlock_retry_jitter = 50         # Random jitter to prevent thundering herd
Hanikamu::Operation.config.redlock_timeout = 0.1             # Redis command timeout
```

### 2. Add Redis to Your Application

**For Development (Docker Compose)**:

```yaml
# docker-compose.yml
services:
  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data
    networks:
      - app_network

  app:
    # ... your app config
    environment:
      REDIS_URL: redis://redis:6379/0
    depends_on:
      - redis
    networks:
      - app_network

volumes:
  redis_data:

networks:
  app_network:
```

**For Production**:

Use a managed Redis service (AWS ElastiCache, Heroku Redis, Redis Labs, etc.) and set the `REDIS_URL` environment variable.

## Usage

### Basic Operation

```ruby
module Types
  include Dry.Types()
end

class CreatePayment < Hanikamu::Operation
  attribute :user_id, Types::Integer
  attribute :amount_cents, Types::Integer
  attribute :payment_method_id, Types::String

  validates :amount_cents, numericality: { greater_than: 0 }

  def execute
    payment = Payment.create!(
      user_id: user_id,
      amount_cents: amount_cents,
      payment_method_id: payment_method_id,
      status: 'completed'
    )

    response payment: payment
  end
end

# Usage
result = CreatePayment.call!(user_id: 123, amount_cents: 5000, payment_method_id: 'pm_123')
# => #<struct payment=#<Payment...>>

# Or with monadic interface
result = CreatePayment.call(user_id: 123, amount_cents: 5000, payment_method_id: 'pm_123')
if result.success?
  payment = result.success.payment
else
  error = result.failure
end
```

### Distributed Locking with `within_mutex`

Prevent concurrent execution using Redis distributed locks (Redlock algorithm):

```ruby
class ProcessSubscriptionRenewal < Hanikamu::Operation
  attribute :subscription_id, Types::Integer

  # Call the mutex_lock method to generate the lock key
  within_mutex(:mutex_lock, expire_milliseconds: 3000)

  def execute
    subscription = Subscription.find(subscription_id)
    subscription.renew!
    subscription.charge_payment!

    response subscription: subscription
  end

  private

  def mutex_lock
    "subscription:#{subscription_id}:renewal"
  end
end

# If another process holds the lock, this raises Redlock::LockError
ProcessSubscriptionRenewal.call!(subscription_id: 456)
```

**How it works**:
- `within_mutex(:method_name)` calls the specified instance method to get the lock key
- Acquires distributed lock before executing
- Lock automatically expires after `expire_milliseconds` (default: 1500ms)
- Raises `Redlock::LockError` if lock cannot be acquired after retries
- Uses Redlock algorithm for distributed systems safety

**Common patterns**:
```ruby
# Lock by resource ID
within_mutex(:stream)

def stream
  "stream:#{stream_id}:processing"
end

# Lock by user
within_mutex(:mutex_lock)

def mutex_lock
  "user:#{user_id}:critical_operation"
end
```

### Database Transactions with `within_transaction`

Wrap operations in database transactions for atomicity:

```ruby
class TransferFunds < Hanikamu::Operation
  attribute :from_account_id, Types::Integer
  attribute :to_account_id, Types::Integer
  attribute :amount_cents, Types::Integer

  validates :amount_cents, numericality: { greater_than: 0 }

  # Use ActiveRecord::Base transaction by default
  within_transaction(:base)

  def execute
    from_account = Account.lock.find(from_account_id)
    to_account = Account.lock.find(to_account_id)

    from_account.withdraw!(amount_cents)
    to_account.deposit!(amount_cents)

    response(
      from_account: from_account,
      to_account: to_account
    )
  end
end

# Both withdrawals and deposits happen atomically
TransferFunds.call!(from_account_id: 1, to_account_id: 2, amount_cents: 10000)
```

**Transaction Options**:
- `within_transaction(:base)` - Use `ActiveRecord::Base.transaction`
- `within_transaction(User)` - Use specific model's transaction (e.g., for multiple databases)

### Form Validations

Use ActiveModel validations on operation inputs:

```ruby
class RegisterUser < Hanikamu::Operation
  attribute :email, Types::String
  attribute :password, Types::String
  attribute :age, Types::Integer

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }
  validates :age, numericality: { greater_than_or_equal_to: 18 }

  def execute
    user = User.create!(email: email, password: password, age: age)
    response user: user
  end
end

# Raises Hanikamu::Operation::FormError with validation messages
RegisterUser.call!(email: 'invalid', password: '123', age: 15)
# => Hanikamu::Operation::FormError: Email is invalid, Password is too short, Age must be >= 18

# With monadic interface
result = RegisterUser.call(email: 'invalid', password: '123', age: 15)
result.failure.errors.full_messages
# => ["Email is invalid", "Password is too short (minimum is 8 characters)", "Age must be greater than or equal to 18"]
```

### Guard Conditions

Implement business rule pre-checks with nested Guard classes:

```ruby
class PublishArticle < Hanikamu::Operation
  attribute :article_id, Types::Integer
  attribute :user_id, Types::Integer

  # Define Guard class for business rule validation
  class Guard
    include ActiveModel::Validations

    attr_reader :operation

    def initialize(operation)
      @operation = operation
      @article = Article.find(operation.article_id)
      @user = User.find(operation.user_id)
    end

    validate :user_must_be_author
    validate :article_must_be_draft

    private

    def user_must_be_author
      errors.add(:user, "must be the article author") unless @article.user_id == @user.id
    end

    def article_must_be_draft
      errors.add(:article, "must be in draft status") unless @article.draft?
    end
  end

  def execute
    article = Article.find(article_id)
    article.update!(status: 'published', published_at: Time.current)

    response article: article
  end
end

# Raises Hanikamu::Operation::GuardError if guard validations fail
PublishArticle.call!(article_id: 999, user_id: 1)
# => Hanikamu::Operation::GuardError: User must be the article author, Article must be in draft status
```

**Guards vs Validations**:
- **Validations**: Input/schema validation (data types, format, presence)
- **Guards**: Business logic validation (permissions, state, pre-conditions)

### Block Requirements

Require a block to be passed to the operation:

```ruby
class BatchProcessRecords < Hanikamu::Operation
  attribute :record_ids, Types::Array.of(Types::Integer)

  block true  # Require a block

  def execute(&block)
    record_ids.each do |id|
      record = Record.find(id)
      yield record  # Yield each record to the caller's block
    end

    response processed_count: record_ids.size
  end
end

# Must provide a block
BatchProcessRecords.call!(record_ids: [1, 2, 3]) do |record|
  puts "Processing #{record.id}"
end

# Without block raises Hanikamu::Operation::MissingBlockError
BatchProcessRecords.call!(record_ids: [1, 2, 3])
# => Hanikamu::Operation::MissingBlockError: This service requires a block to be called
```

### Complete Example: Combining All Features

```ruby
class CheckoutOrder < Hanikamu::Operation
  attribute :order_id, Types::Integer
  attribute :user_id, Types::Integer
  attribute :payment_method_id, Types::String

  # Form validation
  validates :payment_method_id, presence: true

  # Guard conditions
  class Guard
    include ActiveModel::Validations

    attr_reader :operation

    def initialize(operation)
      @operation = operation
      @order = Order.find(operation.order_id)
      @user = User.find(operation.user_id)
    end

    validate :user_owns_order
    validate :order_not_checked_out
    validate :sufficient_inventory

    private

    def user_owns_order
      errors.add(:order, "does not belong to user") unless @order.user_id == @user.id
    end

    def order_not_checked_out
      errors.add(:order, "already checked out") if @order.checked_out?
    end

    def sufficient_inventory
      @order.line_items.each do |item|
        if item.product.stock < item.quantity
          errors.add(:base, "Insufficient stock for #{item.product.name}")
        end
      end
    end
  end

  # Distributed lock to prevent double-checkout
  within_mutex(:mutex_lock, expire_milliseconds: 5000)

  # Database transaction for atomicity
  within_transaction(:base)

  def execute
    order = Order.find(order_id)
    
    # Decrease inventory
    order.line_items.each do |item|
      item.product.decrement!(:stock, item.quantity)
    end

    # Process payment
    payment = Payment.create!(
      order: order,
      user_id: user_id,
      amount_cents: order.total_cents,
      payment_method_id: payment_method_id
    )

    # Mark order as checked out
    order.update!(
      status: 'completed',
      checked_out_at: Time.current
    )

    response order: order, payment: payment
  end

  private

  def mutex_lock
    "order:#{order_id}:checkout"
  end
end

# Usage
result = CheckoutOrder.call(
  order_id: 789,
  user_id: 123,
  payment_method_id: 'pm_abc'
)

if result.success?
  order = result.success.order
  payment = result.success.payment
  # Send confirmation email, etc.
else
  # Handle FormError, GuardError, or other failures
  errors = result.failure
end
```

## Error Handling

### Error Types

| Error Class | When Raised | Contains |
|-------------|-------------|----------|
| `Hanikamu::Operation::FormError` | Input validation fails (ActiveModel validations) | `errors` - ActiveModel::Errors object |
| `Hanikamu::Operation::GuardError` | Guard validation fails (business rules) | `errors` - ActiveModel::Errors object |
| `Hanikamu::Operation::MissingBlockError` | Block required but not provided | Standard error message |
| `Hanikamu::Operation::ConfigurationError` | Redis client not configured | Configuration instructions |
| `Redlock::LockError` | Cannot acquire distributed lock | Lock details |

### Using `.call!` (Raises Exceptions)

```ruby
begin
  result = CreatePayment.call!(user_id: 1, amount_cents: -100, payment_method_id: 'pm_123')
rescue Hanikamu::Operation::FormError => e
  # Input validation failed
  puts e.message  # => "Amount cents must be greater than 0"
  puts e.errors.full_messages
rescue Hanikamu::Operation::GuardError => e
  # Business rule validation failed
  puts e.errors.full_messages
rescue Redlock::LockError => e
  # Could not acquire distributed lock
  puts "Operation locked, try again later"
end
```

### Using `.call` (Returns Monads)

```ruby
result = CreatePayment.call(user_id: 1, amount_cents: -100, payment_method_id: 'pm_123')

case result
when Dry::Monads::Success
  payment = result.success.payment
  puts "Payment created: #{payment.id}"
when Dry::Monads::Failure
  error = result.failure
  
  case error
  when Hanikamu::Operation::FormError
    puts "Validation errors: #{error.errors.full_messages.join(', ')}"
  when Hanikamu::Operation::GuardError
    puts "Business rule violated: #{error.errors.full_messages.join(', ')}"
  when Redlock::LockError
    puts "Resource locked, try again"
  else
    puts "Unknown error: #{error.message}"
  end
end
```

## Configuration Reference

```ruby
# Required
Hanikamu::Operation.config.redis_client = RedisClient.new(url: ENV['REDIS_URL'])

# Optional Redlock settings (defaults shown)
Hanikamu::Operation.config.mutex_expire_milliseconds = 1500  # Lock expires after 1.5 seconds
Hanikamu::Operation.config.redlock_retry_count = 6           # Retry 6 times
Hanikamu::Operation.config.redlock_retry_delay = 500         # Wait 500ms between retries
Hanikamu::Operation.config.redlock_retry_jitter = 50         # Add ±50ms random jitter
Hanikamu::Operation.config.redlock_timeout = 0.1             # Redis command timeout: 100ms
```

## Testing

When testing operations with distributed locks, configure a test Redis instance:

```ruby
# spec/spec_helper.rb or test/test_helper.rb

require 'redis-client'

RSpec.configure do |config|
  config.before(:suite) do
    Hanikamu::Operation.config.redis_client = RedisClient.new(
      url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1')  # Use DB 1 for tests
    )
  end

  config.after(:each) do
    # Clean up Redis between tests if needed
    Hanikamu::Operation.config.redis_client.call('FLUSHDB')
  end
end
```

**Testing Locked Operations**:

```ruby
RSpec.describe ProcessSubscriptionRenewal do
  it "prevents concurrent execution" do
    subscription = create(:subscription)
    lock_key = "subscription:#{subscription.id}:renewal"

    # Simulate another process holding the lock
    Hanikamu::Operation.redis_lock.lock!(lock_key, 2000) do
      expect {
        described_class.call!(subscription_id: subscription.id)
      }.to raise_error(Redlock::LockError)
    end
  end
end
```

## Development

```bash
# Install dependencies
bundle install

# Run tests
make rspec

# Run linter
make cops

# Access console
make console

# Access shell
make shell
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Hanikamu/hanikamu-operation.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Credits

Built by [Hanikamu](https://github.com/Hanikamu) on top of:
- [hanikamu-service](https://github.com/Hanikamu/hanikamu-service) - Base service pattern
- [dry-rb](https://dry-rb.org/) - Type system and monads
- [Redlock](https://github.com/leandromoreira/redlock-rb) - Distributed locking algorithm
