# Otto Getting Started Guide

This guide walks you through installing Otto, creating your first agent, and exploring advanced features. By the end, you'll have a working AI agent that can read files, search code, and help with development tasks.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Quick Start (15 minutes)](#quick-start-15-minutes)
4. [Your First Agent](#your-first-agent)
5. [Working with Tools](#working-with-tools)
6. [Budget Management](#budget-management)
7. [Advanced Configuration](#advanced-configuration)
8. [Common Patterns](#common-patterns)
9. [Troubleshooting](#troubleshooting)
10. [Next Steps](#next-steps)

## Prerequisites

Before starting, ensure you have:

- **Elixir 1.14+** and **Erlang/OTP 25+**
- **PostgreSQL 14+** (for the Phoenix app)
- **ripgrep** (for search functionality): `brew install ripgrep`
- **Anthropic API Key** (get one at [console.anthropic.com](https://console.anthropic.com))

### Verify Prerequisites

```bash
# Check Elixir version
elixir --version
# Erlang/OTP 25 [erts-13.0] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1] [jit:ns]
# Elixir 1.15.4 (compiled with Erlang/OTP 25)

# Check PostgreSQL
psql --version
# psql (PostgreSQL) 15.3

# Check ripgrep
rg --version
# ripgrep 13.0.0

# Check if you can connect to PostgreSQL
psql -h localhost -U postgres -l
```

## Installation

### 1. Clone and Setup

```bash
# Clone the repository
git clone <repository_url> otto
cd otto

# Install dependencies
mix deps.get

# Setup database
mix ecto.create
mix ecto.migrate

# Compile project
mix compile
```

### 2. Configure Environment

Create a `.env` file or set environment variables:

```bash
# .env (or export in your shell)
ANTHROPIC_API_KEY=your_api_key_here
OTTO_ENABLED=true
DATABASE_URL=ecto://postgres:postgres@localhost/otto_live_dev
```

### 3. Start the Application

```bash
# Start Phoenix server
mix phx.server

# Or with IEx for debugging
iex -S mix phx.server
```

You should see:
```
[info] Running OttoLiveWeb.Endpoint with cowboy at 127.0.0.1:4000 (http)
[info] Access OttoLiveWeb.Endpoint at http://localhost:4000
[info] Otto.ToolBus started with 7 built-in tools
[info] Otto system ready
```

### 4. Verify Installation

```bash
# Test the web interface
open http://localhost:4000

# Test IEx access
iex -S mix phx.server
```

In IEx:
```elixir
# Check if Otto modules are loaded
Otto.ToolBus.list_tools()
# => ["fs.read", "fs.write", "grep", "http.get", "json.parse", "yaml.parse", "test.run"]

# Verify configuration loading
{:ok, _config} = Otto.Agent.Config.Loader.load_file("examples/helper.yml")
# => {:ok, %Otto.Agent.Config{...}}
```

## Quick Start (15 minutes)

Let's create a working agent in under 15 minutes:

### Step 1: Create Agent Configuration (2 minutes)

```bash
# Create Otto configuration directory
mkdir -p .otto/agents
```

Create `.otto/agents/helper.yml`:

```yaml
name: "helper"
description: "A helpful coding assistant that can read files and search code"

# Model configuration
model: "claude-3-haiku-20240307"
provider: "anthropic"
system_prompt: |
  You are a helpful coding assistant. You can read files, search for patterns,
  and analyze code. Be concise, accurate, and provide actionable insights.

# Tools available to this agent
tools:
  - "fs.read"
  - "fs.write"
  - "grep"

# Execution environment
working_dir: "."
sandbox:
  enabled: true
  allowed_paths:
    - "."
  denied_patterns:
    - ".env*"
    - "**/*.key"
    - ".git/**"

# Budget limits
budgets:
  time_seconds: 300      # 5 minutes max
  tokens: 15000          # 15k tokens
  cost_cents: 75         # $0.75 max cost

# Tool-specific configuration
tool_config:
  fs.read:
    max_file_size: 2097152  # 2MB max file size

  grep:
    max_results: 100       # Limit search results
    timeout_ms: 10000      # 10 second timeout
```

### Step 2: Test Agent Creation (3 minutes)

Start IEx and test your configuration:

```elixir
# Start IEx
iex -S mix phx.server

# Load the configuration
{:ok, config} = Otto.Agent.Config.Loader.load_file(".otto/agents/helper.yml")

# Verify configuration
config.name
# => "helper"

config.tools
# => ["fs.read", "fs.write", "grep"]

# Check validation
Otto.Agent.Config.validate(config)
# => {:ok, %Otto.Agent.Config{...}}
```

### Step 3: Start Your First Agent (5 minutes)

```elixir
# In IEx, start the agent
{:ok, agent_pid} = Otto.Agent.start_link(config)

# Check agent status
Otto.Agent.get_status(agent_pid)
# => %Otto.Agent.Status{state: :ready, ...}

# Test a simple invocation
{:ok, result} = Otto.Agent.invoke(agent_pid, "Hello! Can you read the README.md file and tell me what this project does?")

# View the result
IO.puts(result.content)
```

### Step 4: Explore Results (5 minutes)

```elixir
# Check what tools were used
result.tool_calls
# => [%{tool: "fs.read", parameters: %{"path" => "README.md"}, ...}]

# View execution metrics
result.usage
# => %{input_tokens: 245, output_tokens: 156, total_tokens: 401}

result.execution_time_ms
# => 2341

# Check budget usage
status = Otto.Agent.get_status(agent_pid)
status.budget_utilization
# => %{time: 0.02, tokens: 0.027, cost: 0.15}
```

🎉 **Congratulations!** You now have a working Otto agent that can read files and respond to questions.

## Your First Agent

Let's dive deeper into creating and configuring agents:

### Agent Naming Convention

Choose meaningful, unique names for your agents:

```yaml
# Good names
name: "helper"           # General purpose
name: "code_reviewer"    # Specific purpose
name: "api_client"       # Clear function
name: "test_runner"      # Action-oriented

# Avoid
name: "Agent1"           # Not descriptive
name: "My Cool Agent"    # Spaces not allowed
name: "super-agent"      # Mixed case issues
```

### Model Selection

Choose the right model for your use case:

```yaml
# For quick, simple tasks
model: "claude-3-haiku-20240307"
# - Fastest and cheapest
# - Good for basic file operations
# - Cost: ~$0.025 per 1K input tokens

# For complex reasoning
model: "claude-3-sonnet-20240229"
# - Balanced speed and capability
# - Good for code analysis
# - Cost: ~$0.30 per 1K input tokens

# For most sophisticated tasks
model: "claude-3-opus-20240229"
# - Highest capability
# - Best for complex reasoning
# - Cost: ~$1.50 per 1K input tokens

# Latest and greatest
model: "claude-3-5-sonnet-20240620"
# - Best overall model
# - Excellent code understanding
# - Cost: ~$0.30 per 1K input tokens
```

### System Prompts

Craft effective system prompts for your agents:

```yaml
# Basic prompt
system_prompt: "You are a helpful coding assistant."

# Detailed prompt with personality
system_prompt: |
  You are a senior software engineer helping with code review and development.

  Your approach:
  - Be thorough but concise
  - Focus on practical solutions
  - Explain your reasoning
  - Point out potential issues
  - Suggest improvements

  When reading code:
  - Look for bugs, security issues, and performance problems
  - Consider maintainability and best practices
  - Check for proper error handling

  When writing code:
  - Follow language conventions
  - Write clear, readable code
  - Include appropriate comments
  - Handle edge cases

# Context-aware prompt
system_prompt: |
  You are working on an Elixir/Phoenix project called Otto.
  Otto is an AI agent framework built with OTP patterns.

  Key technologies:
  - Elixir 1.15+ with OTP
  - Phoenix LiveView for web UI
  - PostgreSQL for data storage
  - Anthropic Claude for LLM

  When helping with this project:
  - Use Elixir idioms and patterns
  - Follow OTP supervision principles
  - Consider GenServer patterns
  - Focus on fault tolerance
```

### Tool Selection

Choose tools based on your agent's purpose:

```yaml
# File-focused agent
tools:
  - "fs.read"
  - "fs.write"
  - "grep"

# Web-focused agent
tools:
  - "http.get"
  - "http.post"
  - "json.parse"

# Development agent
tools:
  - "fs.read"
  - "fs.write"
  - "grep"
  - "test.run"

# Full-featured agent
tools:
  - "fs.read"
  - "fs.write"
  - "grep"
  - "http.get"
  - "http.post"
  - "json.parse"
  - "yaml.parse"
  - "test.run"
```

## Working with Tools

Otto's built-in tools provide essential capabilities. Let's explore each one:

### File System Tools

#### Reading Files

```elixir
# Read a specific file
{:ok, result} = Otto.Agent.invoke(agent_pid, "Read the mix.exs file and tell me about the project dependencies")

# Read multiple files
{:ok, result} = Otto.Agent.invoke(agent_pid, """
Read these files and summarize their purpose:
- lib/otto/agent.ex
- lib/otto/tool_bus.ex
- README.md
""")

# Read with size limits (configured in tool_config)
```

Example tool configuration:
```yaml
tool_config:
  fs.read:
    max_file_size: 5242880  # 5MB limit
    encoding: "utf-8"       # File encoding
    binary_detection: true  # Auto-detect binary files
```

#### Writing Files

```elixir
# Create new files
{:ok, result} = Otto.Agent.invoke(agent_pid, """
Create a new file called 'hello.ex' with a simple Elixir module that defines a hello/0 function returning "Hello, Otto!"
""")

# Modify existing files
{:ok, result} = Otto.Agent.invoke(agent_pid, """
Read the README.md file and add a new section called "Quick Setup" with installation instructions
""")
```

Tool configuration:
```yaml
tool_config:
  fs.write:
    backup_on_overwrite: true    # Create .bak files
    atomic_writes: true          # Use temp file + rename
    create_directories: true     # Create parent directories
    file_mode: 0644             # File permissions
```

### Search Tools

#### Using grep

```elixir
# Search for patterns
{:ok, result} = Otto.Agent.invoke(agent_pid, "Search for all functions that use GenServer.call in the codebase")

# Search in specific directories
{:ok, result} = Otto.Agent.invoke(agent_pid, "Find all test files that test the Agent module")

# Search with context
{:ok, result} = Otto.Agent.invoke(agent_pid, "Look for any TODO or FIXME comments in the lib/ directory")
```

Configure search behavior:
```yaml
tool_config:
  grep:
    max_results: 500         # Limit results
    timeout_ms: 15000        # Search timeout
    case_sensitive: false    # Case insensitive by default
    include_line_numbers: true
    context_lines: 2         # Lines around matches
```

### HTTP Tools

#### Making API Calls

```elixir
# GET requests
{:ok, result} = Otto.Agent.invoke(agent_pid, """
Fetch information about the Otto project from GitHub API.
Use the endpoint: https://api.github.com/repos/owner/otto
""")

# POST requests with JSON
{:ok, result} = Otto.Agent.invoke(agent_pid, """
Send a webhook notification to https://hooks.example.com/webhook
Include a JSON payload with status: "agent_completed" and timestamp.
""")
```

HTTP tool configuration:
```yaml
tool_config:
  http.get:
    timeout_ms: 30000
    follow_redirects: true
    max_redirects: 5
    allowed_domains:           # Security allowlist
      - "api.github.com"
      - "jsonplaceholder.typicode.com"
    headers:
      User-Agent: "Otto-Agent/0.1.0"
      Accept: "application/json"

  http.post:
    timeout_ms: 60000
    content_type: "application/json"
    retry_on_timeout: true
```

### Data Processing Tools

#### JSON and YAML

```elixir
# Parse and analyze JSON
{:ok, result} = Otto.Agent.invoke(agent_pid, """
Read the package.json file, parse it, and tell me what dependencies need to be updated
""")

# Generate configuration
{:ok, result} = Otto.Agent.invoke(agent_pid, """
Create a YAML configuration file for a new agent called "database_helper" that can read and write files and make HTTP requests
""")
```

### Test Runner

```elixir
# Run specific tests
{:ok, result} = Otto.Agent.invoke(agent_pid, "Run the tests for the Agent module and tell me if they pass")

# Run with coverage
{:ok, result} = Otto.Agent.invoke(agent_pid, "Run all tests and report on code coverage")

# Analyze test failures
{:ok, result} = Otto.Agent.invoke(agent_pid, "Run the tests and if any fail, analyze the failure and suggest fixes")
```

Test configuration:
```yaml
tool_config:
  test.run:
    timeout_ms: 300000       # 5 minutes for tests
    parallel: true           # Run tests in parallel
    coverage: true           # Collect coverage
    env:                     # Environment variables
      MIX_ENV: "test"
      DATABASE_URL: "ecto://localhost/otto_test"
```

## Budget Management

Otto provides three types of budgets to control costs and execution:

### Time Budgets

Prevent runaway executions:

```yaml
budgets:
  time_seconds: 300          # 5 minutes total
```

Time budget enforcement:
- Tracks wall-clock time from invocation start
- Sends warning at 80% utilization
- Hard stop at 100%
- Graceful shutdown preserves partial results

### Token Budgets

Control LLM usage:

```yaml
budgets:
  tokens: 50000              # 50k input + output tokens
```

Token budget features:
- Pre-flight estimation prevents overruns
- Real-time tracking during streaming
- Includes tool call descriptions in count
- Warning at 80% usage

### Cost Budgets

Manage financial limits:

```yaml
budgets:
  cost_cents: 500            # $5.00 maximum cost
```

Cost calculation:
- Based on current model pricing
- Includes input and output tokens
- Updates in real-time
- Accurate to the cent

### Budget Examples

```yaml
# Conservative budget for experimentation
budgets:
  time_seconds: 120          # 2 minutes
  tokens: 5000               # 5k tokens
  cost_cents: 25             # $0.25

# Development budget
budgets:
  time_seconds: 600          # 10 minutes
  tokens: 25000              # 25k tokens
  cost_cents: 200            # $2.00

# Production budget for complex tasks
budgets:
  time_seconds: 1800         # 30 minutes
  tokens: 100000             # 100k tokens
  cost_cents: 1000           # $10.00
```

### Monitoring Budget Usage

```elixir
# Check current usage
status = Otto.Agent.get_status(agent_pid)
status.budget_utilization
# => %{
#      time: 0.15,      # 15% of time budget used
#      tokens: 0.23,    # 23% of tokens used
#      cost: 0.08       # 8% of cost budget used
#    }

# Get detailed budget info
status.budgets
# => %{
#      time: %{limit: 300, used: 45, remaining: 255},
#      tokens: %{limit: 15000, used: 3450, remaining: 11550},
#      cost: %{limit: 75, used: 6, remaining: 69}
#    }
```

## Advanced Configuration

### Environment-Specific Configs

Create different configurations for different environments:

```yaml
# .otto/environments/development.yml
budgets:
  time_seconds: 1800         # Generous limits for development
  tokens: 100000
  cost_cents: 2000

sandbox:
  enabled: false             # No sandbox in development

tool_config:
  http.get:
    allowed_domains: ["*"]   # Allow all domains in dev
```

```yaml
# .otto/environments/production.yml
budgets:
  time_seconds: 300          # Strict limits in production
  tokens: 10000
  cost_cents: 100

sandbox:
  enabled: true              # Always sandboxed in production
  allowed_paths:
    - "app/"
    - "lib/"
  denied_patterns:
    - "**/*.key"
    - ".env*"

tool_config:
  http.get:
    allowed_domains:         # Explicit allowlist
      - "api.internal.com"
      - "trusted-service.com"
```

### Configuration Layering

Otto loads configurations in order of precedence:

1. **Built-in defaults** (hardcoded)
2. **Global defaults** (`.otto/agents/defaults.yml`)
3. **Agent config** (`.otto/agents/{name}.yml`)
4. **Environment overrides** (`.otto/environments/{env}.yml`)
5. **Runtime parameters** (passed to agent startup)

Example layering:

```yaml
# .otto/agents/defaults.yml
budgets:
  time_seconds: 300
  tokens: 10000
  cost_cents: 100

tool_config:
  fs.read:
    max_file_size: 2097152

sandbox:
  enabled: true
```

```yaml
# .otto/agents/helper.yml (inherits from defaults)
name: "helper"
model: "claude-3-haiku-20240307"
tools: ["fs.read", "fs.write", "grep"]

# Overrides defaults
budgets:
  tokens: 15000              # Increased token limit

tool_config:
  fs.read:
    max_file_size: 5242880   # Increased file size limit
```

### Environment Variable Interpolation

Use environment variables in configurations:

```yaml
# Dynamic configuration based on environment
name: "${AGENT_NAME:-helper}"
description: "Agent for ${ENVIRONMENT:-development} environment"

model: "${LLM_MODEL:-claude-3-haiku-20240307}"

system_prompt: |
  You are working in ${ENVIRONMENT:-development} mode.
  Environment: ${RAILS_ENV:-development}
  Version: ${APP_VERSION:-unknown}

tool_config:
  http.get:
    headers:
      Authorization: "Bearer ${API_TOKEN}"
      User-Agent: "Otto/${VERSION:-0.1.0}"
    base_url: "${API_BASE_URL:-https://api.example.com}"
    timeout_ms: ${HTTP_TIMEOUT_MS:-30000}

budgets:
  time_seconds: ${BUDGET_TIME_SECONDS:-300}
  tokens: ${BUDGET_TOKENS:-10000}
  cost_cents: ${BUDGET_COST_CENTS:-100}
```

Set environment variables:

```bash
export AGENT_NAME="production_helper"
export ENVIRONMENT="production"
export LLM_MODEL="claude-3-sonnet-20240229"
export API_TOKEN="your_api_token_here"
export API_BASE_URL="https://api.production.com"
export BUDGET_COST_CENTS="50"
```

### Custom Tool Configuration

Configure tools for specific use cases:

```yaml
# Research agent configuration
name: "researcher"
tools: ["http.get", "json.parse", "fs.write"]

tool_config:
  http.get:
    timeout_ms: 60000        # Longer timeout for research
    allowed_domains:
      - "api.github.com"
      - "docs.elixir-lang.org"
      - "hexdocs.pm"
      - "stackoverflow.com"
    headers:
      Accept: "application/json"
      User-Agent: "Otto-Researcher/0.1.0"

  fs.write:
    backup_on_overwrite: true
    create_directories: true
    file_mode: 0644
```

## Common Patterns

### Pattern 1: Code Review Agent

```yaml
name: "code_reviewer"
description: "Reviews code for bugs, style, and best practices"

model: "claude-3-5-sonnet-20240620"
system_prompt: |
  You are a senior software engineer performing thorough code reviews.

  Focus on:
  - Bugs and potential issues
  - Security vulnerabilities
  - Performance considerations
  - Code style and maintainability
  - Best practices adherence

  Provide:
  - Specific line-by-line feedback
  - Actionable improvement suggestions
  - Explanations for your recommendations

tools:
  - "fs.read"
  - "grep"
  - "test.run"

working_dir: "."
sandbox:
  enabled: true
  allowed_paths: ["lib/", "test/", "src/", "apps/"]

budgets:
  time_seconds: 900          # 15 minutes for thorough review
  tokens: 50000              # Large token budget for detailed feedback
  cost_cents: 400            # $4.00 for comprehensive review

tool_config:
  grep:
    max_results: 200
    context_lines: 3

  test.run:
    timeout_ms: 180000       # 3 minutes for tests
    coverage: true
```

Usage:
```elixir
{:ok, agent} = Otto.Agent.Config.Loader.load_file(".otto/agents/code_reviewer.yml")
|> then(fn {:ok, config} -> Otto.Agent.start_link(config) end)

{:ok, result} = Otto.Agent.invoke(agent, """
Please review the lib/otto/agent/server.ex file. Look for:
1. Potential bugs or edge cases
2. Performance issues
3. Code organization improvements
4. Missing error handling
5. Test coverage gaps
""")
```

### Pattern 2: API Integration Helper

```yaml
name: "api_helper"
description: "Helps integrate with external APIs"

model: "claude-3-sonnet-20240229"
system_prompt: |
  You are an API integration specialist. You help developers work with
  REST APIs by making requests, parsing responses, and handling errors.

  Best practices:
  - Always check response status codes
  - Handle rate limiting gracefully
  - Parse JSON responses carefully
  - Provide clear error messages
  - Suggest retry strategies

tools:
  - "http.get"
  - "http.post"
  - "json.parse"
  - "fs.write"

permissions:
  - read
  - write
  - network

tool_config:
  http.get:
    timeout_ms: 45000
    retry_on_timeout: true
    allowed_domains:
      - "api.github.com"
      - "jsonplaceholder.typicode.com"
      - "httpbin.org"
    headers:
      User-Agent: "Otto-API-Helper/0.1.0"
      Accept: "application/json"

  http.post:
    timeout_ms: 60000
    content_type: "application/json"

budgets:
  time_seconds: 600
  tokens: 30000
  cost_cents: 300
```

### Pattern 3: Test Helper Agent

```yaml
name: "test_helper"
description: "Helps write, run, and debug tests"

model: "claude-3-haiku-20240307"
system_prompt: |
  You are a testing specialist focused on helping developers write,
  run, and debug tests. You understand various testing patterns and
  can help identify test coverage gaps.

tools:
  - "fs.read"
  - "fs.write"
  - "grep"
  - "test.run"

tool_config:
  test.run:
    timeout_ms: 300000       # 5 minutes for test execution
    parallel: true
    coverage: true
    env:
      MIX_ENV: "test"

  grep:
    max_results: 100
    case_sensitive: false

  fs.read:
    max_file_size: 1048576   # 1MB for test files

budgets:
  time_seconds: 600
  tokens: 20000
  cost_cents: 150
```

### Pattern 4: Documentation Generator

```yaml
name: "doc_generator"
description: "Generates and maintains project documentation"

model: "claude-3-5-sonnet-20240620"
system_prompt: |
  You are a technical writer who creates clear, comprehensive documentation.

  Documentation principles:
  - Write for the audience (beginners vs experts)
  - Include practical examples
  - Keep it up-to-date with code changes
  - Use clear, concise language
  - Provide both overview and reference material

tools:
  - "fs.read"
  - "fs.write"
  - "grep"

working_dir: "."
sandbox:
  enabled: true
  allowed_paths:
    - "docs/"
    - "lib/"
    - "README.md"
    - "CHANGELOG.md"

tool_config:
  fs.write:
    backup_on_overwrite: true
    create_directories: true

budgets:
  time_seconds: 1200         # 20 minutes for documentation
  tokens: 75000
  cost_cents: 600
```

## Troubleshooting

### Common Issues

#### 1. Agent Won't Start

**Symptoms:**
```elixir
{:error, {:initialization_failed, reason}}
```

**Solutions:**
```elixir
# Check configuration validity
{:ok, config} = Otto.Agent.Config.Loader.load_file(".otto/agents/helper.yml")
case Otto.Agent.Config.validate(config) do
  {:ok, _} -> IO.puts("Config is valid")
  {:error, changeset} ->
    IO.inspect(changeset.errors)
end

# Verify tools are registered
Otto.ToolBus.list_tools()

# Check working directory exists and is readable
File.exists?(config.working_dir)
File.dir?(config.working_dir)
```

#### 2. Budget Exceeded Immediately

**Symptoms:**
```elixir
{:error, {:budget_exceeded, :tokens, %{estimated: 15000, remaining: 10000}}}
```

**Solutions:**
```yaml
# Increase token budget
budgets:
  tokens: 25000              # Increased from 10000

# Or use a more efficient model
model: "claude-3-haiku-20240307"  # More token-efficient

# Reduce system prompt length
system_prompt: "You are a helpful assistant."  # Shorter prompt
```

#### 3. Tool Permission Denied

**Symptoms:**
```
{:error, "Tool requires :network permission but agent only has [:read, :write]"}
```

**Solutions:**
```yaml
# Add required permissions explicitly
permissions:
  - read
  - write
  - network              # Add missing permission

# Or let Otto derive permissions from tools
# (remove permissions field and let it auto-derive)
```

#### 4. Sandbox Violations

**Symptoms:**
```
{:error, "File access denied by sandbox: /etc/passwd"}
```

**Solutions:**
```yaml
sandbox:
  enabled: true
  allowed_paths:
    - "."                # Allow current directory
    - "/app"             # Add specific paths
  denied_patterns:
    - "**/*.secret"      # Keep security patterns
```

#### 5. API Key Issues

**Symptoms:**
```
{:error, {:llm_error, :unauthorized, "Invalid API key"}}
```

**Solutions:**
```bash
# Verify API key is set
echo $ANTHROPIC_API_KEY

# Check API key format (should start with 'sk-')
# Get a new key from https://console.anthropic.com

# Test API key directly
curl -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
     https://api.anthropic.com/v1/messages
```

### Debug Mode

Enable debug logging for troubleshooting:

```bash
# Start with debug logging
OTTO_LOG_LEVEL=debug iex -S mix phx.server
```

```elixir
# In IEx, enable detailed logging
Logger.configure(level: :debug)

# Monitor agent state
agent_pid |> :sys.get_state() |> IO.inspect()

# Watch telemetry events
:telemetry.attach(:otto_debug, [:otto, :agent], fn event, measurements, metadata, _ ->
  IO.puts("Event: #{inspect(event)}")
  IO.puts("Data: #{inspect({measurements, metadata})}")
end, nil)
```

### Getting Help

1. **Check logs** - Most issues are logged with helpful error messages
2. **Validate configuration** - Use `Otto.Agent.Config.validate/1`
3. **Test tools individually** - Use `Otto.ToolBus.call_tool/3` directly
4. **Review budget usage** - Check if limits are too restrictive
5. **Verify environment** - Ensure API keys and dependencies are correct

## Next Steps

Now that you have Otto working, explore these advanced topics:

### 1. Custom Tools
- Create domain-specific tools for your use case
- Implement the `Otto.Tool` behavior
- Add custom validation and error handling

### 2. Multi-Agent Patterns
- Coordinate multiple agents for complex tasks
- Share context between agents
- Implement agent handoff patterns

### 3. Production Deployment
- Configure monitoring and observability
- Set up proper error handling and alerting
- Implement backup and recovery procedures

### 4. Integration Patterns
- Embed agents in Phoenix LiveView applications
- Create agent-powered API endpoints
- Build workflow automation systems

### 5. Advanced Configuration
- Environment-specific configurations
- Dynamic configuration loading
- Configuration validation pipelines

### Useful Resources

- **[Tools API Reference](tools-api.md)** - Complete tool documentation
- **[Agent Configuration](agent-config-api.md)** - Configuration reference
- **[AgentServer API](agent-server-api.md)** - Server lifecycle and state
- **[Operational Guide](operational-guide.md)** - Production deployment
- **Examples Directory** - Real-world configuration examples

### Community

- **GitHub Issues** - Report bugs and request features
- **Discussions** - Ask questions and share patterns
- **Contributing** - Help improve Otto for everyone

---

You're now ready to build powerful AI agents with Otto! Start with simple use cases and gradually explore more advanced patterns as you become comfortable with the system.