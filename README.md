# Hanikamu::Operation

[![ci](https://github.com/Hanikamu/hanikamu-operation/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-operation/actions/workflows/ci.yml)

A Ruby gem that extends [hanikamu-service](https://github.com/Hanikamu/hanikamu-service) with advanced operation patterns including distributed locking, database transactions, form validations, and guard conditions. Perfect for building robust, concurrent-safe business operations in Rails applications.

## Table of Contents

1. [Why Hanikamu::Operation?](#why-hanikamuoperation)
2. [Quick Start](#quick-start)
3. [Installation](#installation)
4. [Setup](#setup)
5. [Usage](#usage)
   - [Basic Operation](#basic-operation)
   - [Distributed Locking](#distributed-locking-with-within_mutex)
   - [Database Transactions](#database-transactions-with-within_transaction)
   - [Form Validations](#form-validations)
   - [Guard Conditions](#guard-conditions)
   - [Block Requirements](#block-requirements)
   - [Complete Example](#complete-example-combining-all-features)
6. [Error Handling](#error-handling)
7. [Best Practices](#best-practices)
8. [Configuration Reference](#configuration-reference)
9. [Testing](#testing)
10. [Development](#development)
11. [Contributing](#contributing)
12. [License](#license)
13. [Credits](#credits)

## Why Hanikamu::Operation?

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

## Quick Start

**1. Install the gem**

```ruby
# Gemfile
gem 'hanikamu-operation', '~> 0.1.1'
```

```bash
bundle install
```

**2. Configure Redis (required for distributed locking)**

```ruby
# config/initializers/hanikamu_operation.rb
require 'redis-client'

Hanikamu::Operation.configure do |config|
  config.redis_client = RedisClient.new(url: ENV.fetch('REDIS_URL'))
end
```

**3. Create an operation**

```ruby
class Payments::ChargeOperation < Hanikamu::Operation
  attribute :user_id, Types::Integer
  validates :user_id, presence: true

  within_mutex(:mutex_lock)
  within_transaction(:base)

  def execute
    user = User.find(user_id)
    user.charge!
    response user: user
  end

  private

  def mutex_lock
    "user:#{user_id}:charge"
  end
end
```

**4. Call the operation**

```ruby
# Raises exceptions on failure
Payments::ChargeOperation.call!(user_id: current_user.id)

# Returns Success/Failure monad
result = Payments::ChargeOperation.call(user_id: current_user.id)
if result.success?
  user = result.success.user
else
  errors = result.failure
end
```

## Installation

Add to your application's Gemfile:

```ruby
gem 'hanikamu-operation', '~> 0.1.1'
```

Then execute:

```bash
bundle install
```

## Setup

### Rails Application Setup Guide

Follow these steps to integrate Hanikamu::Operation into a Rails application:

**Step 1: Add the gem to your Gemfile**

```ruby
# Gemfile
gem 'hanikamu-operation', '~> 0.1.1'
gem 'redis-client', '~> 0.22'  # Required for distributed locking
```

```bash
bundle install
```

**Step 2: Define your Types module**

```ruby
# app/types.rb
module Types
  include Dry.Types()
end
```

**Step 3: Create the initializer**

```ruby
# config/initializers/hanikamu_operation.rb
require 'redis-client'

Hanikamu::Operation.configure do |config|
  config.redis_client = RedisClient.new(
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    reconnect_attempts: 3,
    timeout: 1.0
  )
end
```

**Step 4: Add Redis to your development environment**

For Docker Compose:

```yaml
# docker-compose.yml
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data

  web:
    # ... your Rails app config
    environment:
      REDIS_URL: redis://redis:6379/0
    depends_on:
      - redis

volumes:
  redis_data:
```

For local development without Docker:

```bash
# macOS with Homebrew
brew install redis
brew services start redis

# Your .env file
REDIS_URL=redis://localhost:6379/0
```

**Step 5: Create your first operation**

```bash
# Create operations directory
mkdir -p app/operations/users
```

```ruby
# app/operations/users/create_user_operation.rb
module Users
  class CreateUserOperation < Hanikamu::Operation
    attribute :email, Types::String
    attribute :password, Types::String

    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :password, length: { minimum: 8 }

    within_transaction(:base)

    def execute
      user = User.create!(
        email: email,
        password: password
      )

      response user: user
    end
  end
end
```

**Step 6: Use in your controller**

```ruby
# app/controllers/users_controller.rb
class UsersController < ApplicationController
  def create
    result = Users::CreateUserOperation.call(user_params)

    if result.success?
      user = result.success.user
      render json: { user: user }, status: :created
    else
      error = result.failure
      case error
      when Hanikamu::Operation::FormError
        render json: { errors: error.errors.full_messages }, status: :unprocessable_entity
      else
        render json: { error: error.message }, status: :internal_server_error
      end
    end
  end

  private

  def user_params
    params.require(:user).permit(:email, :password)
  end
end
```

**Step 7: Configure for production**

Set your Redis URL in production (Heroku, AWS, etc.):

```bash
# Heroku
heroku addons:create heroku-redis:mini
# REDIS_URL is automatically set

# Or set manually
heroku config:set REDIS_URL=redis://your-redis-host:6379/0
```

### Detailed Configuration Options

If you need more control, create a detailed initializer:

```ruby
# config/initializers/hanikamu_operation.rb
require 'redis-client'

Hanikamu::Operation.configure do |config|
  # Required: Redis client for distributed locking
  config.redis_client = RedisClient.new(
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    reconnect_attempts: 3,
    timeout: 1.0
  )

  # Optional: Customize Redlock settings (these are the defaults)
  config.mutex_expire_milliseconds = 1500  # Lock TTL
  config.redlock_retry_count = 6           # Number of retry attempts
  config.redlock_retry_delay = 500         # Milliseconds between retries
  config.redlock_retry_jitter = 50         # Random jitter to prevent thundering herd
  config.redlock_timeout = 0.1             # Redis command timeout

  # Optional: Add errors to whitelist (Redlock::LockError is always included by default)
  config.whitelisted_errors = [CustomBusinessError]
end
```

### Redis Setup by Environment

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

Hanikamu::Operation provides five key features that you can combine as needed:

| Feature | Declaration | Purpose |
|---------|-------------|----------|
| **Input Attributes** | `attribute :name, Type` | Define typed input parameters |
| **Form Validations** | `validates :field, ...` | Validate input values (format, presence, etc.) |
| **Guard Conditions** | `guard do ... end` | Validate business rules and state before execution |
| **Distributed Locking** | `within_mutex(:method)` | Prevent concurrent execution of the same resource |
| **Database Transactions** | `within_transaction(:base)` | Wrap execution in an atomic database transaction |
| **Block Requirement** | `block true` | Require a block to be passed to the operation |

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

Prevent race conditions by ensuring only one process can execute the operation for a specific resource at a time. Uses the Redlock algorithm for distributed systems safety.

```ruby
class ProcessSubscriptionRenewal < Hanikamu::Operation
  attribute :subscription_id, Types::Integer

  # The :mutex_lock method will be called to generate the lock identifier
  within_mutex(:mutex_lock, expire_milliseconds: 3000)

  def execute
    subscription = Subscription.find(subscription_id)
    subscription.renew!
    subscription.charge_payment!

    response subscription: subscription
  end

  private

  # This method returns the Redis lock key
  # Must be unique per resource you want to lock
  def mutex_lock
    "subscription:#{subscription_id}:renewal"
  end
end

# If another process holds the lock, this raises Redlock::LockError
ProcessSubscriptionRenewal.call!(subscription_id: 456)
```

**How it works**:
1. `within_mutex(:method_name)` tells the operation which method to call for the lock key
2. Before `execute` runs, the operation calls your method (e.g., `mutex_lock`) to get a unique string
3. It attempts to acquire a distributed lock using that key
4. If successful, `execute` runs and the lock is released afterward
5. If the lock can't be acquired, raises `Redlock::LockError`
6. Locks automatically expire after `expire_milliseconds` (default: 1500ms) to prevent deadlocks

**Key points**:
- The method name (`:mutex_lock`) can be anything you want
- The method must return a string that uniquely identifies the resource being locked
- Use different lock keys for different types of operations on the same resource
- Common pattern: `"resource_type:#{id}:operation_name"`

**Common patterns**:
```ruby
# Lock by resource ID
within_mutex(:mutex_lock)

def mutex_lock
  "stream:#{stream_id}:processing"
end

# Lock by multiple attributes
within_mutex(:mutex_lock)

def mutex_lock
  "user:#{user_id}:account:#{account_id}:transfer"
end
```

### Database Transactions with `within_transaction`

Ensure multiple database changes succeed or fail together atomically. If any database operation raises an exception, all changes are rolled back.

```ruby
class TransferFunds < Hanikamu::Operation
  attribute :from_account_id, Types::Integer
  attribute :to_account_id, Types::Integer
  attribute :amount_cents, Types::Integer

  validates :amount_cents, numericality: { greater_than: 0 }

  # Wrap the execute method in a database transaction
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

# Both withdraw and deposit happen atomically
# If either fails, both are rolled back
TransferFunds.call!(from_account_id: 1, to_account_id: 2, amount_cents: 10000)
```

**Transaction Options**:
- `within_transaction(:base)` - Use `ActiveRecord::Base.transaction` (most common)
- `within_transaction(User)` - Use a specific model's transaction (useful for multiple databases)

**Important**: Use transactions when you have multiple database writes that must succeed or fail together. Without a transaction, if the second write fails, the first write remains in the database.

### Form Validations

Validate input values using familiar ActiveModel validations. These run after type checking but before guards and execution.

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

# Invalid inputs raise FormError
RegisterUser.call!(email: 'invalid', password: '123', age: 15)
# => Hanikamu::Operation::FormError: Email is invalid, Password is too short, Age must be >= 18

# With monadic interface
result = RegisterUser.call(email: 'invalid', password: '123', age: 15)
result.failure.errors.full_messages
# => ["Email is invalid", "Password is too short (minimum is 8 characters)", "Age must be greater than or equal to 18"]
```

**When to use**: Validate input format, presence, length, format, or value ranges. If correcting the input arguments could make the operation succeed, use form validations.

### Guard Conditions

Validate business rules, permissions, and system state before execution. Unlike form validations (which check input values), guards check whether the operation can proceed given the current state of your system.

```ruby
class PublishArticle < Hanikamu::Operation
  attribute :article_id, Types::Integer
  attribute :user_id, Types::Integer

  # Define guard conditions using a block
  guard do
    # Access operation attributes directly using delegates
    delegates :article_id, :user_id
    
    validate :user_must_be_author
    validate :article_must_be_draft

    def article
      @article ||= Article.find(article_id)
    end

    def user
      @user ||= User.find(user_id)
    end

    def user_must_be_author
      errors.add(:user, "must be the article author") unless article.user_id == user.id
    end

    def article_must_be_draft
      errors.add(:article, "must be in draft status") unless article.draft?
    end
  end

  def execute
    article = Article.find(article_id)
    article.update!(status: 'published', published_at: Time.current)

    response article: article
  end
end

# Raises GuardError if guards fail
PublishArticle.call!(article_id: 999, user_id: 1)
# => Hanikamu::Operation::GuardError: User must be the article author, Article must be in draft status
```

**Form Validations vs Guards**:

| | Form Validations | Guards |
|---|---|---|
| **Purpose** | Validate input values | Validate system state and business rules |
| **Example** | Email format, password length | User permissions, resource status |
| **Error** | `FormError` | `GuardError` |
| **When** | After type check, before guards | After validations, before execution |
| **Can succeed later?** | Yes, by correcting inputs | Maybe, if system state changes |

**When to use guards**: Check permissions, verify resource state, enforce business rules that depend on the current state of your system (not just the input values).

### Block Requirements

Some operations need to yield data back to the caller (for batch processing, streaming, etc.). Use `block true` to enforce that a block is provided.

```ruby
class BatchProcessRecords < Hanikamu::Operation
  attribute :record_ids, Types::Array.of(Types::Integer)

  block true  # Callers must provide a block

  def execute(&block)
    record_ids.each do |id|
      record = Record.find(id)
      yield record  # Pass each record to the caller
    end

    response processed_count: record_ids.size
  end
end

# Valid usage with a block
BatchProcessRecords.call!(record_ids: [1, 2, 3]) do |record|
  puts "Processing #{record.id}"
end

# Calling without a block raises an error
BatchProcessRecords.call!(record_ids: [1, 2, 3])
# => Hanikamu::Operation::MissingBlockError: This service requires a block to be called
```

**When to use**: Batch processors, iterators, or any operation where the caller needs to handle each item individually.

### Complete Example: Combining All Features

```ruby
class CheckoutOrder < Hanikamu::Operation
  attribute :order_id, Types::Integer
  attribute :user_id, Types::Integer
  attribute :payment_method_id, Types::String

  # Form validation
  validates :payment_method_id, presence: true

  # Guard conditions using a block
  guard do
    # Shortcut helper to delegate to the operation instance
    delegates :order_id, :user_id
    
    validate :user_owns_order
    validate :order_not_checked_out
    validate :sufficient_inventory

    def order
      @order ||= Order.find(order_id)
    end

    def user
      @user ||= User.find(user_id)
    end

    def user_owns_order
      errors.add(:order, "does not belong to user") unless order.user_id == user.id
    end

    def order_not_checked_out
      errors.add(:order, "already checked out") if order.checked_out?
    end

    def sufficient_inventory
      order.line_items.each do |item|
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

### Understanding Validation Layers

Operations validate at three distinct levels, each serving a specific purpose:

**1. Type Validation (Dry::Struct::Error)**
- Validates that input arguments are of the correct type
- Raised automatically by dry-struct before the operation executes
- Example: Passing a string when an integer is expected

**2. Form Validation (Hanikamu::Operation::FormError)**
- Validates input argument values and basic business rules
- Raised when the provided values don't meet criteria
- **Key principle**: Correcting the arguments may allow the operation to succeed
- Examples: Missing required fields, invalid format, duplicate values, out-of-range numbers

**3. Guard Validation (Hanikamu::Operation::GuardError)**
- Validates system state and pre-conditions
- Raised when arguments are valid but the system state prevents execution
- **Key principle**: The operation cannot proceed due to current state, regardless of argument changes
- Examples: Resource already processed, insufficient permissions, preconditions not met

### Error Types Reference

| Error Class | When Raised | Contains |
|-------------|-------------|----------|
| `Dry::Struct::Error` | Type validation fails (wrong argument types) | Type error details |
| `Hanikamu::Operation::FormError` | Input validation fails (ActiveModel validations) | `errors` - ActiveModel::Errors object |
| `Hanikamu::Operation::GuardError` | Guard validation fails (business rules/state) | `errors` - ActiveModel::Errors object |
| `Hanikamu::Operation::MissingBlockError` | Block required but not provided | Standard error message |
| `Hanikamu::Operation::ConfigurationError` | Redis client not configured | Configuration instructions |
| `Redlock::LockError` | Cannot acquire distributed lock | Lock details (always whitelisted by default) |

### FormError vs GuardError: Practical Examples

**FormError Example** - Invalid or incorrect input arguments:

```ruby
# Attempting to create a user with invalid inputs
result = Users::CreateUserOperation.call(
  email: "taken@example.com",
  password: "short",
  password_confirmation: "wrong"
)
# => Failure(#<Hanikamu::Operation::FormError: 
#      Email has been taken, 
#      Password is too short, 
#      Password confirmation does not match password>)

# Correcting the arguments allows success
result = Users::CreateUserOperation.call(
  email: "unique@example.com",
  password: "securePassword123!",
  password_confirmation: "securePassword123!"
)
# => Success(#<struct user=#<User id: 46, email: "unique@example.com">>)
```

**GuardError Example** - Valid arguments but invalid system state:

```ruby
# First attempt succeeds
result = Users::CompleteUserOperation.call!(user_id: 46)
# => Success(#<struct user=#<User id: 46, completed_at: "2025-11-26">>)

# Second attempt fails due to state, even with valid arguments
result = Users::CompleteUserOperation.call!(user_id: 46)
# => Failure(#<Hanikamu::Operation::GuardError: User has already been completed>)

# The arguments are still correct, but the operation cannot proceed
# because the user's state has changed
```

**Type Error Example** - Wrong argument type:

```ruby
# Passing wrong type raises immediately
Users::CompleteUserOperation.call!(user_id: "not-a-number")
# => Raises Dry::Struct::Error
```

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

## Best Practices

### Single Responsibility Principle
Each operation should handle one specific type of state change with a clear, unambiguous interface. Avoid operations that do multiple unrelated things.

### Naming Conventions

Operations should follow this naming pattern:

**Format**: `[Namespace(s)]::[Verb][Noun]Operation`

Examples:
- `Users::CreateUserOperation`
- `Orders::CompleteCheckoutOperation`  
- `Payments::ProcessRefundOperation`
- `Portfolios::Saxo::CreateTransactionsOperation`

Use imperative verb forms (Create, Update, Complete, Process, Cancel) that clearly communicate the action being performed.

### Robust Validation Strategy

1. **Type Safety First**: Use Dry::Types for all attributes to catch type errors early
2. **Form Validations**: Validate argument values using ActiveModel validations
3. **Guard Conditions**: Validate system state and preconditions before execution
4. **Clear Error Messages**: Provide actionable error messages that guide users to corrections

### Use the Response Helper

Always return a response struct from your operations:

```ruby
def execute
  user = User.create!(email: email, password: password)
  
  # Good: Explicit response with clear interface
  response user: user
  
  # Avoid: Implicit return
  # user
end
```

Benefits:
- Provides clear interface for testing
- Makes return values explicit
- Allows for easy extension (add more fields to response)

### Comprehensive Testing

Write tests for each operation covering:
- **Happy path**: Valid inputs and successful execution
- **Type validation**: Wrong argument types
- **Form validation**: Invalid argument values  
- **Guard validation**: Invalid system states
- **Edge cases**: Boundary conditions and race scenarios
- **Concurrency**: Multiple simultaneous executions (if using mutexes)

### Transaction and Lock Ordering

When combining features, use this order:

```ruby
class MyOperation < Hanikamu::Operation
  # 1. Guards (validate state first)
  guard do
    # validations
  end
  
  # 2. Mutex (acquire lock)
  within_mutex(:mutex_lock)
  
  # 3. Transaction (wrap database changes)
  within_transaction(:base)
  
  def execute
    # implementation
  end
end
```

## Configuration Reference

```ruby
Hanikamu::Operation.configure do |config|
  # Required
  config.redis_client = RedisClient.new(url: ENV['REDIS_URL'])

  # Optional Redlock settings (defaults shown)
  config.mutex_expire_milliseconds = 1500  # Lock expires after 1.5 seconds
  config.redlock_retry_count = 6           # Retry 6 times
  config.redlock_retry_delay = 500         # Wait 500ms between retries
  config.redlock_retry_jitter = 50         # Add ±50ms random jitter
  config.redlock_timeout = 0.1             # Redis command timeout: 100ms

  # Optional error whitelisting (Redlock::LockError always included by default)
  config.whitelisted_errors = []  # Add custom errors here
end
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
