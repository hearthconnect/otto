# Configure test environment
ExUnit.start()

# Only run integration tests if explicitly requested
unless System.get_env("INTEGRATION_TESTS") do
  ExUnit.configure(exclude: [integration: true])
end

# Mark slow tests to be excluded by default
unless System.get_env("SLOW_TESTS") do
  ExUnit.configure(exclude: [slow: true])
end
