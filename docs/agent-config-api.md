# Otto Agent Configuration API

This document provides complete API documentation for Otto agent configuration, including the `Otto.Agent.Config` struct, YAML schema validation, and configuration loading mechanisms.

## Table of Contents

1. [Otto.Agent.Config Struct](#ottoagentconfig-struct)
2. [YAML Configuration Schema](#yaml-configuration-schema)
3. [Configuration Loading](#configuration-loading)
4. [Validation Rules](#validation-rules)
5. [Environment Variable Interpolation](#environment-variable-interpolation)
6. [Tool Configuration](#tool-configuration)
7. [Budget Configuration](#budget-configuration)
8. [Sandbox Configuration](#sandbox-configuration)
9. [Configuration Examples](#configuration-examples)
10. [API Reference](#api-reference)

## Otto.Agent.Config Struct

The `Otto.Agent.Config` struct represents a complete agent configuration with all necessary parameters for agent lifecycle management.

### Struct Definition

```elixir
defmodule Otto.Agent.Config do
  @moduledoc """
  Configuration structure for Otto agents.

  Defines all parameters needed to spawn and manage an agent process,
  including model settings, tool permissions, budget limits, and
  execution environment constraints.
  """

  @type budget :: %{
    time_seconds: pos_integer() | nil,
    tokens: pos_integer() | nil,
    cost_cents: pos_integer() | nil
  }

  @type sandbox :: %{
    enabled: boolean(),
    allowed_paths: [String.t()],
    denied_patterns: [String.t()],
    max_file_size: pos_integer(),
    follow_symlinks: boolean()
  }

  @type tool_config :: %{
    String.t() => map()
  }

  @type t :: %__MODULE__{
    # Identity
    name: String.t(),
    description: String.t() | nil,

    # Model Configuration
    model: String.t(),
    provider: String.t(),
    system_prompt: String.t() | nil,
    temperature: float() | nil,
    max_tokens: pos_integer() | nil,

    # Tools and Permissions
    tools: [String.t()],
    permissions: [atom()],
    tool_config: tool_config(),

    # Execution Environment
    working_dir: String.t(),
    sandbox: sandbox() | nil,

    # Budget Controls
    budgets: budget(),

    # Runtime Configuration
    timeout_ms: pos_integer(),
    retry_attempts: non_neg_integer(),
    checkpoint_enabled: boolean(),
    transcript_limit: pos_integer() | nil,

    # Metadata
    tags: [String.t()],
    metadata: map(),
    created_at: DateTime.t(),
    updated_at: DateTime.t()
  }

  defstruct [
    # Identity
    name: nil,
    description: nil,

    # Model Configuration
    model: "claude-3-haiku-20240307",
    provider: "anthropic",
    system_prompt: nil,
    temperature: nil,
    max_tokens: nil,

    # Tools and Permissions
    tools: [],
    permissions: [:read],
    tool_config: %{},

    # Execution Environment
    working_dir: ".",
    sandbox: nil,

    # Budget Controls
    budgets: %{
      time_seconds: 300,
      tokens: 10_000,
      cost_cents: 100
    },

    # Runtime Configuration
    timeout_ms: 120_000,
    retry_attempts: 3,
    checkpoint_enabled: true,
    transcript_limit: 1000,

    # Metadata
    tags: [],
    metadata: %{},
    created_at: nil,
    updated_at: nil
  ]

  @doc """
  Creates a new agent configuration from a map of parameters.

  ## Parameters

  - `params`: Map with configuration parameters
  - `opts`: Options for validation and processing

  ## Returns

  - `{:ok, %Otto.Agent.Config{}}`: Valid configuration
  - `{:error, changeset}`: Validation errors

  ## Examples

      iex> params = %{
      ...>   "name" => "helper",
      ...>   "tools" => ["fs.read", "fs.write"],
      ...>   "budgets" => %{"time_seconds" => 600}
      ...> }
      iex> Otto.Agent.Config.new(params)
      {:ok, %Otto.Agent.Config{name: "helper", ...}}

  """
  @spec new(map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(params, opts \\ [])

  @doc """
  Creates a new configuration, raising on validation errors.

  ## Examples

      iex> Otto.Agent.Config.new!(%{"name" => "helper"})
      %Otto.Agent.Config{name: "helper", ...}

      iex> Otto.Agent.Config.new!(%{})
      ** (Otto.ConfigError) Configuration validation failed: name is required

  """
  @spec new!(map(), keyword()) :: t()
  def new!(params, opts \\ [])

  @doc """
  Validates a configuration struct or parameters.

  ## Examples

      iex> config = %Otto.Agent.Config{name: "helper"}
      iex> Otto.Agent.Config.validate(config)
      {:ok, config}

      iex> config = %Otto.Agent.Config{name: nil}
      iex> Otto.Agent.Config.validate(config)
      {:error, %Ecto.Changeset{valid?: false, ...}}

  """
  @spec validate(t() | map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def validate(config_or_params)

  @doc """
  Updates an existing configuration with new parameters.

  ## Examples

      iex> config = %Otto.Agent.Config{name: "helper"}
      iex> Otto.Agent.Config.update(config, %{"description" => "A helpful agent"})
      {:ok, %Otto.Agent.Config{name: "helper", description: "A helpful agent"}}

  """
  @spec update(t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update(config, params)

  @doc """
  Merges two configurations, with the second taking precedence.

  Used for layering user/project/environment configurations.

  ## Examples

      iex> base = %Otto.Agent.Config{name: "helper", tools: ["fs.read"]}
      iex> override = %Otto.Agent.Config{tools: ["fs.read", "fs.write"]}
      iex> Otto.Agent.Config.merge(base, override)
      %Otto.Agent.Config{name: "helper", tools: ["fs.read", "fs.write"]}

  """
  @spec merge(t(), t()) :: t()
  def merge(base_config, override_config)
end
```

## YAML Configuration Schema

Agents are configured using YAML files with a specific schema. The YAML format provides a human-readable way to define agent behavior.

### Complete YAML Schema

```yaml
# Agent Identity (Required)
name: string                    # Unique agent identifier
description: string             # Human-readable description (optional)

# Model Configuration (Required)
model: string                   # LLM model identifier
provider: string                # LLM provider (default: "anthropic")
system_prompt: |                # Multi-line system prompt (optional)
  string
temperature: float              # Model temperature 0.0-2.0 (optional)
max_tokens: integer            # Max output tokens (optional)

# Tools and Permissions (Required)
tools:                         # List of tool names
  - string
permissions:                   # Permission levels (optional, derived from tools)
  - read
  - write
  - exec
  - network

# Execution Environment
working_dir: string            # Working directory (default: ".")
sandbox:                       # Sandbox configuration (optional)
  enabled: boolean             # Enable sandboxing (default: false)
  allowed_paths:               # Allowed path patterns
    - string
  denied_patterns:             # Denied path patterns
    - string
  max_file_size: integer       # Max file size in bytes (default: 2MB)
  follow_symlinks: boolean     # Follow symbolic links (default: false)

# Budget Controls
budgets:
  time_seconds: integer        # Max execution time (default: 300)
  tokens: integer              # Max tokens per invocation (default: 10000)
  cost_cents: integer          # Max cost in cents (default: 100)

# Tool-Specific Configuration
tool_config:
  tool_name:                   # Configuration for specific tools
    key: value

# Runtime Configuration (Optional)
timeout_ms: integer            # Request timeout (default: 120000)
retry_attempts: integer        # Max retry attempts (default: 3)
checkpoint_enabled: boolean    # Enable checkpointing (default: true)
transcript_limit: integer      # Max transcript entries (default: 1000)

# Metadata (Optional)
tags:                          # Agent tags for organization
  - string
metadata:                      # Additional metadata
  key: value
```

### JSON Schema Definition

Otto also provides a JSON Schema for validation:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "title": "Otto Agent Configuration",
  "description": "Configuration schema for Otto AI agents",
  "required": ["name", "model", "tools"],
  "properties": {
    "name": {
      "type": "string",
      "pattern": "^[a-zA-Z0-9_-]+$",
      "minLength": 1,
      "maxLength": 64,
      "description": "Unique identifier for the agent"
    },
    "description": {
      "type": "string",
      "maxLength": 500,
      "description": "Human-readable description of the agent's purpose"
    },
    "model": {
      "type": "string",
      "enum": [
        "claude-3-opus-20240229",
        "claude-3-sonnet-20240229",
        "claude-3-haiku-20240307",
        "claude-3-5-sonnet-20240620"
      ],
      "description": "LLM model to use for this agent"
    },
    "provider": {
      "type": "string",
      "enum": ["anthropic"],
      "default": "anthropic",
      "description": "LLM provider"
    },
    "system_prompt": {
      "type": "string",
      "maxLength": 10000,
      "description": "System prompt that defines the agent's behavior"
    },
    "temperature": {
      "type": "number",
      "minimum": 0.0,
      "maximum": 2.0,
      "description": "Model temperature for response randomness"
    },
    "max_tokens": {
      "type": "integer",
      "minimum": 1,
      "maximum": 200000,
      "description": "Maximum tokens in model response"
    },
    "tools": {
      "type": "array",
      "items": {
        "type": "string",
        "pattern": "^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$"
      },
      "minItems": 0,
      "maxItems": 50,
      "uniqueItems": true,
      "description": "List of tools available to the agent"
    },
    "permissions": {
      "type": "array",
      "items": {
        "type": "string",
        "enum": ["read", "write", "exec", "network"]
      },
      "uniqueItems": true,
      "description": "Permissions granted to the agent"
    },
    "working_dir": {
      "type": "string",
      "default": ".",
      "description": "Working directory for agent operations"
    },
    "sandbox": {
      "type": "object",
      "properties": {
        "enabled": {
          "type": "boolean",
          "default": false
        },
        "allowed_paths": {
          "type": "array",
          "items": {"type": "string"}
        },
        "denied_patterns": {
          "type": "array",
          "items": {"type": "string"}
        },
        "max_file_size": {
          "type": "integer",
          "default": 2097152,
          "minimum": 1
        },
        "follow_symlinks": {
          "type": "boolean",
          "default": false
        }
      },
      "additionalProperties": false
    },
    "budgets": {
      "type": "object",
      "properties": {
        "time_seconds": {
          "type": "integer",
          "minimum": 1,
          "maximum": 3600,
          "default": 300
        },
        "tokens": {
          "type": "integer",
          "minimum": 1,
          "maximum": 1000000,
          "default": 10000
        },
        "cost_cents": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10000,
          "default": 100
        }
      },
      "additionalProperties": false
    },
    "tool_config": {
      "type": "object",
      "patternProperties": {
        "^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$": {
          "type": "object"
        }
      },
      "additionalProperties": false
    },
    "timeout_ms": {
      "type": "integer",
      "minimum": 1000,
      "maximum": 600000,
      "default": 120000
    },
    "retry_attempts": {
      "type": "integer",
      "minimum": 0,
      "maximum": 10,
      "default": 3
    },
    "checkpoint_enabled": {
      "type": "boolean",
      "default": true
    },
    "transcript_limit": {
      "type": "integer",
      "minimum": 10,
      "maximum": 10000,
      "default": 1000
    },
    "tags": {
      "type": "array",
      "items": {"type": "string"},
      "uniqueItems": true
    },
    "metadata": {
      "type": "object",
      "additionalProperties": true
    }
  },
  "additionalProperties": false
}
```

## Configuration Loading

Otto provides multiple mechanisms for loading and managing agent configurations.

### File-based Loading

```elixir
defmodule Otto.Agent.Config.Loader do
  @doc """
  Load configuration from a YAML file.

  ## Parameters

  - `file_path`: Path to YAML configuration file
  - `opts`: Loading options

  ## Options

  - `:validate` - Validate configuration (default: true)
  - `:interpolate` - Interpolate environment variables (default: true)
  - `:merge_defaults` - Merge with default values (default: true)

  ## Examples

      iex> Otto.Agent.Config.Loader.load_file(".otto/agents/helper.yml")
      {:ok, %Otto.Agent.Config{name: "helper", ...}}

      iex> Otto.Agent.Config.Loader.load_file("nonexistent.yml")
      {:error, %Otto.ConfigError{reason: :file_not_found}}

  """
  @spec load_file(String.t(), keyword()) :: {:ok, Otto.Agent.Config.t()} | {:error, any()}
  def load_file(file_path, opts \\ [])

  @doc """
  Load all configurations from a directory.

  Scans for *.yml files and loads each as a separate configuration.

  ## Examples

      iex> Otto.Agent.Config.Loader.load_directory(".otto/agents/")
      {:ok, [
        %Otto.Agent.Config{name: "helper", ...},
        %Otto.Agent.Config{name: "reviewer", ...}
      ]}

  """
  @spec load_directory(String.t(), keyword()) :: {:ok, [Otto.Agent.Config.t()]} | {:error, any()}
  def load_directory(dir_path, opts \\ [])

  @doc """
  Load configuration from multiple sources with precedence.

  Sources are merged with later sources taking precedence.

  ## Examples

      iex> sources = [
      ...>   {:file, "defaults.yml"},
      ...>   {:file, ".otto/agents/helper.yml"},
      ...>   {:env, "OTTO_AGENT_CONFIG"}
      ...> ]
      iex> Otto.Agent.Config.Loader.load_with_precedence(sources)
      {:ok, %Otto.Agent.Config{...}}

  """
  @spec load_with_precedence([{:file | :env | :map, String.t() | map()}], keyword()) ::
    {:ok, Otto.Agent.Config.t()} | {:error, any()}
  def load_with_precedence(sources, opts \\ [])
end
```

### Directory Structure

Otto follows a conventional directory structure for configuration files:

```
.otto/
├── agents/                 # Agent configurations
│   ├── helper.yml         # Individual agent config
│   ├── reviewer.yml       # Another agent config
│   └── defaults.yml       # Default configuration
├── tools/                 # Custom tool configurations
│   └── database.yml       # Tool-specific config
└── environments/          # Environment-specific configs
    ├── development.yml    # Dev environment overrides
    ├── staging.yml        # Staging environment overrides
    └── production.yml     # Production environment overrides
```

### Configuration Precedence

Otto applies configuration in the following order (later sources override earlier ones):

1. **Built-in Defaults** - Hard-coded default values
2. **Global Defaults** - `.otto/agents/defaults.yml`
3. **Agent Configuration** - `.otto/agents/{agent_name}.yml`
4. **Environment Overrides** - `.otto/environments/{env}.yml`
5. **Runtime Parameters** - Passed to agent startup

## Validation Rules

Otto enforces strict validation rules to ensure configuration integrity:

### Name Validation

```elixir
# Valid names
"helper"
"code_reviewer"
"slack-notifier"
"api_client_v2"

# Invalid names
"Helper"           # No uppercase
"my agent"         # No spaces
"agent@work"       # No special chars
""                 # Not empty
"a" * 65           # Max 64 characters
```

### Tool Validation

```elixir
# Valid tool names
"fs.read"
"http.get"
"database.query"
"slack.notify"

# Invalid tool names
"FileRead"         # No camelCase
"fs-read"          # No hyphens
"fs..read"         # No double dots
".read"            # No leading dot
```

### Budget Validation

All budget values must be positive integers within reasonable bounds:

```elixir
budgets:
  time_seconds: 1..3600      # 1 second to 1 hour
  tokens: 1..1_000_000       # 1 to 1M tokens
  cost_cents: 1..10_000      # 1 cent to $100
```

### Model Validation

Only supported models are allowed:

```elixir
valid_models = [
  "claude-3-opus-20240229",
  "claude-3-sonnet-20240229",
  "claude-3-haiku-20240307",
  "claude-3-5-sonnet-20240620"
]
```

## Environment Variable Interpolation

Otto supports environment variable interpolation in configuration values:

### Interpolation Syntax

```yaml
# Basic interpolation
api_key: "${API_KEY}"

# With default values
api_key: "${API_KEY:-default_key}"

# Nested interpolation
system_prompt: |
  You are an assistant working in ${ENVIRONMENT:-development} mode.
  Your API endpoint is ${API_BASE_URL}/v1.

# Tool configuration
tool_config:
  http.get:
    headers:
      Authorization: "Bearer ${BEARER_TOKEN}"
    base_url: "${API_BASE_URL:-https://api.example.com}"
```

### Interpolation Rules

1. **Syntax**: `${VAR_NAME}` or `${VAR_NAME:-default}`
2. **Nesting**: Variables can reference other variables
3. **Type Preservation**: Numeric and boolean values are preserved
4. **Security**: Sensitive values are masked in logs

### Example with Interpolation

```yaml
# .otto/agents/api_client.yml
name: "api_client"
description: "Client for ${SERVICE_NAME:-external} API"

system_prompt: |
  You are an API client for the ${SERVICE_NAME} service.
  Base URL: ${API_BASE_URL}
  Environment: ${ENVIRONMENT}

tools:
  - "http.get"
  - "http.post"
  - "json.parse"

tool_config:
  http.get:
    base_url: "${API_BASE_URL}"
    headers:
      Authorization: "Bearer ${API_TOKEN}"
      User-Agent: "Otto/${OTTO_VERSION:-0.1.0}"
    timeout_ms: ${HTTP_TIMEOUT_MS:-30000}

budgets:
  time_seconds: ${BUDGET_TIME:-300}
  tokens: ${BUDGET_TOKENS:-10000}
  cost_cents: ${BUDGET_COST_CENTS:-100}
```

## Tool Configuration

Tools can be configured with specific parameters through the `tool_config` section:

### File System Tools

```yaml
tool_config:
  fs.read:
    max_file_size: 5242880        # 5MB limit
    encoding: "utf-8"             # File encoding
    binary_detection: true        # Detect binary files

  fs.write:
    backup_on_overwrite: true     # Create .bak files
    atomic_writes: true           # Use temp file + rename
    file_mode: 0644               # File permissions
    create_directories: true      # Create parent dirs
```

### HTTP Tools

```yaml
tool_config:
  http.get:
    timeout_ms: 30000            # Request timeout
    follow_redirects: true       # Follow HTTP redirects
    max_redirects: 5             # Max redirect hops
    allowed_domains:             # Domain allowlist
      - "api.github.com"
      - "httpbin.org"
    headers:                     # Default headers
      User-Agent: "Otto/0.1.0"
      Accept: "application/json"

  http.post:
    timeout_ms: 60000
    content_type: "application/json"
    retry_on_timeout: true
```

### Search Tools

```yaml
tool_config:
  grep:
    max_results: 1000            # Limit search results
    timeout_ms: 15000            # Search timeout
    case_sensitive: false        # Case insensitive by default
    include_line_numbers: true   # Include line numbers
    context_lines: 2             # Lines of context around matches
```

### Test Tools

```yaml
tool_config:
  test.run:
    timeout_ms: 300000           # 5 minute test timeout
    parallel: true               # Run tests in parallel
    coverage: true               # Collect coverage data
    env:                         # Environment variables
      MIX_ENV: "test"
      DATABASE_URL: "ecto://localhost/otto_test"
```

## Budget Configuration

Budgets provide multi-dimensional cost control for agent execution:

### Budget Types

```yaml
budgets:
  # Time-based budget
  time_seconds: 600              # Maximum execution time

  # Token-based budget
  tokens: 50000                  # Input + output tokens

  # Cost-based budget
  cost_cents: 500                # Maximum cost in cents ($5.00)
```

### Budget Enforcement

Otto enforces budgets at multiple points:

1. **Pre-execution**: Check if operation would exceed budget
2. **During execution**: Monitor token usage and time
3. **Post-execution**: Update usage counters

### Budget Sharing

Budgets can be shared across multiple invocations:

```yaml
budgets:
  time_seconds: 1800             # 30 minutes total
  tokens: 100000                 # 100k tokens total
  cost_cents: 1000               # $10.00 total

  # Budget sharing configuration
  sharing:
    scope: "session"             # session, agent, global
    reset_interval: "daily"      # hourly, daily, weekly, monthly
```

## Sandbox Configuration

Sandboxes provide security isolation for agent operations:

### Basic Sandbox

```yaml
sandbox:
  enabled: true                  # Enable sandboxing
  allowed_paths:                 # Allowed path prefixes
    - "/app/src"
    - "/app/test"
    - "/app/docs"
  denied_patterns:               # Denied glob patterns
    - "**/.git/**"
    - "**/*.secret"
    - ".env*"
    - "**/node_modules/**"
```

### Advanced Sandbox

```yaml
sandbox:
  enabled: true
  mode: "strict"                 # strict, permissive

  # Path configuration
  allowed_paths:
    - "/app/src"
    - "/app/test"
  denied_patterns:
    - "**/*.key"
    - "**/*.pem"

  # File size limits
  max_file_size: 10485760        # 10MB
  max_total_size: 104857600      # 100MB total

  # Behavior configuration
  follow_symlinks: false         # Don't follow symlinks
  allow_hidden_files: false      # Deny dotfiles
  case_sensitive: true           # Case sensitive paths

  # Network restrictions
  network_access: false          # Deny all network access
  allowed_domains: []            # No domains allowed

  # Process restrictions
  allow_subprocess: false        # Deny subprocess spawning
  max_processes: 0               # No additional processes
```

## Configuration Examples

### Basic Helper Agent

```yaml
# .otto/agents/helper.yml
name: "helper"
description: "A general-purpose coding assistant"

model: "claude-3-haiku-20240307"
system_prompt: |
  You are a helpful coding assistant. You can read and write files,
  search for patterns, and run tests. Be concise and accurate.

tools:
  - "fs.read"
  - "fs.write"
  - "grep"
  - "test.run"

working_dir: "."
sandbox:
  enabled: true
  allowed_paths:
    - "."
  denied_patterns:
    - ".env*"
    - "**/*.key"
    - ".git/**"

budgets:
  time_seconds: 300
  tokens: 15000
  cost_cents: 75
```

### API Integration Agent

```yaml
# .otto/agents/api_client.yml
name: "api_client"
description: "Integrates with external APIs and processes responses"

model: "claude-3-sonnet-20240229"
system_prompt: |
  You are an API integration specialist. You make HTTP requests,
  parse JSON responses, and handle API errors gracefully.

tools:
  - "http.get"
  - "http.post"
  - "json.parse"
  - "yaml.parse"

permissions:
  - read
  - network

tool_config:
  http.get:
    timeout_ms: 45000
    allowed_domains:
      - "api.github.com"
      - "jsonplaceholder.typicode.com"
    headers:
      User-Agent: "Otto-Agent/0.1.0"

  http.post:
    timeout_ms: 60000
    content_type: "application/json"

budgets:
  time_seconds: 900              # 15 minutes
  tokens: 25000
  cost_cents: 200                # $2.00
```

### Code Review Agent

```yaml
# .otto/agents/reviewer.yml
name: "code_reviewer"
description: "Reviews code for bugs, style, and best practices"

model: "claude-3-opus-20240229"
system_prompt: |
  You are a senior software engineer performing code reviews.
  Look for bugs, security issues, performance problems, and
  adherence to best practices. Provide constructive feedback.

tools:
  - "fs.read"
  - "grep"
  - "test.run"

working_dir: "."
sandbox:
  enabled: true
  allowed_paths:
    - "lib/"
    - "test/"
    - "src/"
    - "apps/"
  max_file_size: 1048576         # 1MB files max

tool_config:
  grep:
    max_results: 500
    context_lines: 3
    case_sensitive: false

  test.run:
    timeout_ms: 180000           # 3 minutes for tests
    coverage: true

budgets:
  time_seconds: 1200             # 20 minutes
  tokens: 75000                  # Large token budget
  cost_cents: 800                # $8.00

tags:
  - "code-review"
  - "quality-assurance"

metadata:
  review_type: "automated"
  severity_threshold: "medium"
```

### Development Environment Agent

```yaml
# .otto/agents/dev_assistant.yml
name: "dev_assistant"
description: "Development environment helper with full access"

model: "claude-3-5-sonnet-20240620"
system_prompt: |
  You are a development assistant with access to the full project.
  Help with coding, debugging, testing, and project management.
  You have extensive permissions - use them responsibly.

tools:
  - "fs.read"
  - "fs.write"
  - "grep"
  - "http.get"
  - "http.post"
  - "json.parse"
  - "yaml.parse"
  - "test.run"

permissions:
  - read
  - write
  - exec
  - network

# No sandbox in development
sandbox:
  enabled: false

tool_config:
  fs.read:
    max_file_size: 10485760      # 10MB files

  fs.write:
    backup_on_overwrite: true
    create_directories: true

  http.get:
    timeout_ms: 60000
    # Allow all domains in development
    allowed_domains: ["*"]

  test.run:
    timeout_ms: 600000           # 10 minutes for tests
    parallel: true
    coverage: true

budgets:
  time_seconds: 1800             # 30 minutes
  tokens: 100000                 # 100k tokens
  cost_cents: 2000               # $20.00

metadata:
  environment: "development"
  full_access: true
```

## API Reference

### Otto.Agent.Config.new/2

Creates a new agent configuration from parameters.

```elixir
@spec new(map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}

# Examples
{:ok, config} = Otto.Agent.Config.new(%{
  "name" => "helper",
  "model" => "claude-3-haiku-20240307",
  "tools" => ["fs.read", "fs.write"]
})

# With validation options
{:ok, config} = Otto.Agent.Config.new(params, validate: true, interpolate: false)
```

### Otto.Agent.Config.validate/1

Validates configuration parameters or struct.

```elixir
@spec validate(t() | map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}

# Validate struct
{:ok, config} = Otto.Agent.Config.validate(config)

# Validate parameters
case Otto.Agent.Config.validate(params) do
  {:ok, config} -> {:ok, config}
  {:error, changeset} ->
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
    {:error, errors}
end
```

### Otto.Agent.Config.merge/2

Merges two configurations with precedence.

```elixir
@spec merge(t(), t()) :: t()

base_config = %Otto.Agent.Config{name: "helper", tools: ["fs.read"]}
override_config = %Otto.Agent.Config{tools: ["fs.read", "fs.write"]}

merged = Otto.Agent.Config.merge(base_config, override_config)
# => %Otto.Agent.Config{name: "helper", tools: ["fs.read", "fs.write"]}
```

### Otto.Agent.Config.Loader.load_file/2

Loads configuration from YAML file.

```elixir
@spec load_file(String.t(), keyword()) :: {:ok, t()} | {:error, any()}

# Basic loading
{:ok, config} = Otto.Agent.Config.Loader.load_file(".otto/agents/helper.yml")

# With options
{:ok, config} = Otto.Agent.Config.Loader.load_file(
  "config.yml",
  validate: true,
  interpolate: true,
  merge_defaults: true
)
```

### Otto.Agent.Config.Loader.load_directory/2

Loads all configurations from directory.

```elixir
@spec load_directory(String.t(), keyword()) :: {:ok, [t()]} | {:error, any()}

{:ok, configs} = Otto.Agent.Config.Loader.load_directory(".otto/agents/")

# Filter by tags
{:ok, configs} = Otto.Agent.Config.Loader.load_directory(
  ".otto/agents/",
  filter: fn config -> "development" in config.tags end
)
```

### Validation Functions

```elixir
# Check if name is valid
Otto.Agent.Config.valid_name?("helper")          # => true
Otto.Agent.Config.valid_name?("Helper")          # => false

# Check if model is supported
Otto.Agent.Config.valid_model?("claude-3-haiku-20240307")  # => true

# Validate tool name format
Otto.Agent.Config.valid_tool_name?("fs.read")    # => true
Otto.Agent.Config.valid_tool_name?("FileRead")   # => false

# Check budget constraints
Otto.Agent.Config.valid_budget?(%{time_seconds: 300, tokens: 10000})  # => true
```

### Error Types

```elixir
defmodule Otto.ConfigError do
  defexception [:message, :reason, :details]

  # Common error reasons:
  # :file_not_found
  # :invalid_yaml
  # :validation_failed
  # :interpolation_failed
  # :tool_not_found
  # :model_not_supported
end
```

---

This comprehensive documentation covers all aspects of Otto agent configuration. For more examples and best practices, see the [Getting Started Guide](getting-started.md) and [Configuration Examples](../examples/configs/).