# frozen_string_literal: true

require "hanikamu-operation"
require "redis-client"

module Types
  include Dry::Types()
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Configure Hanikamu::Operation with test Redis client
  config.before(:suite) do
    redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")

    Hanikamu::Operation.configure do |op_config|
      op_config.redis_client = RedisClient.new(url: redis_url)
    end

    # Flush test DB to avoid residual locks between runs
    begin
      Hanikamu::Operation.config.redis_client.call("FLUSHDB")
    rescue StandardError
      # ignore if Redis is not available locally; CI provides Redis
    end
  end

  # Reset redis_lock instance and test module between tests to ensure clean state
  config.before do
    Hanikamu::Operation.instance_variable_set(:@redis_lock, nil)
    Object.send(:remove_const, :TestModule) if Object.const_defined?(:TestModule)
    Object.const_set(:TestModule, Module.new)
  end

  config.after(:suite) do
    # Flush test DB after suite completes

    Hanikamu::Operation.config.redis_client.call("FLUSHDB")
  rescue StandardError
    # ignore if Redis is not available

  end
end

# Helper: wait_until for polling-based expectations to reduce flakiness
def wait_until?(timeout: 2, interval: 0.05)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    return true if yield
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start > timeout

    sleep interval
  end
  false
end
