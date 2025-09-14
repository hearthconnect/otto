# Otto Tools API Reference

This document provides comprehensive API documentation for the Otto tool system, including the `Otto.Tool` behaviour, `Otto.ToolBus` registry, and built-in tool implementations.

## Table of Contents

1. [Otto.Tool Behaviour](#ottotool-behaviour)
2. [Otto.ToolBus Registry](#ottotoolbus-registry)
3. [Built-in Tools](#built-in-tools)
4. [Custom Tool Development](#custom-tool-development)
5. [Permission Model](#permission-model)
6. [Tool Context](#tool-context)
7. [Error Handling](#error-handling)
8. [Testing Tools](#testing-tools)

## Otto.Tool Behaviour

The `Otto.Tool` behaviour defines the contract that all tools must implement to be compatible with the Otto agent system.

### Behaviour Definition

```elixir
defmodule Otto.Tool do
  @moduledoc """
  Behaviour for implementing Otto tools.

  Tools are discrete capabilities that agents can invoke to interact with
  external systems, perform computations, or manipulate data. Each tool
  declares its name, required permissions, and implements a call/2 function.
  """

  @doc """
  Returns the unique name identifier for this tool.

  The name is used by agents to reference the tool in their configuration
  and during invocation. Names should be descriptive and use dot notation
  for hierarchical organization (e.g., "fs.read", "http.get").
  """
  @callback name() :: String.t()

  @doc """
  Returns the list of permissions required by this tool.

  Permissions control what capabilities the tool needs to function properly.
  Available permissions: :read, :write, :exec, :network
  """
  @callback permissions() :: [atom()]

  @doc """
  Executes the tool with given parameters and context.

  ## Parameters

  - `params`: Map containing tool-specific parameters
  - `context`: %Otto.ToolContext{} with agent info and runtime data

  ## Returns

  - `{:ok, result}`: Successful execution with result data
  - `{:error, reason}`: Execution failed with error details
  """
  @callback call(params :: map(), context :: Otto.ToolContext.t()) ::
    {:ok, any()} | {:error, any()}

  @doc """
  Optional callback for tool-specific validation of parameters.

  Called before tool execution to validate input parameters.
  If not implemented, no validation is performed.
  """
  @callback validate_params(params :: map()) :: :ok | {:error, String.t()}

  @doc """
  Optional callback that returns the JSON schema for tool parameters.

  Used for documentation generation and parameter validation.
  If not implemented, no schema validation is performed.
  """
  @callback param_schema() :: map()

  @optional_callbacks [validate_params: 1, param_schema: 0]
end
```

### Implementation Example

```elixir
defmodule MyApp.Tools.FileReader do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "fs.read"

  @impl Otto.Tool
  def permissions, do: [:read]

  @impl Otto.Tool
  def call(%{"path" => path} = params, %Otto.ToolContext{} = context) do
    file_path = resolve_path(path, context.working_dir)

    with :ok <- validate_sandbox(file_path, context),
         :ok <- validate_file_size(file_path, params["max_size"]),
         {:ok, content} <- File.read(file_path) do
      {:ok, %{content: content, path: file_path, size: byte_size(content)}}
    else
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, :eacces} -> {:error, "Permission denied: #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Otto.Tool
  def validate_params(%{"path" => path}) when is_binary(path), do: :ok
  def validate_params(_), do: {:error, "path parameter is required"}

  @impl Otto.Tool
  def param_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path to read"
        },
        "max_size" => %{
          "type" => "integer",
          "description" => "Maximum file size in bytes",
          "default" => 2_097_152
        }
      },
      "required" => ["path"]
    }
  end

  defp resolve_path(path, working_dir) do
    Path.expand(path, working_dir)
  end

  defp validate_sandbox(file_path, %{sandbox: true, allowed_paths: paths}) do
    if Enum.any?(paths, &String.starts_with?(file_path, &1)) do
      :ok
    else
      {:error, "File access denied by sandbox: #{file_path}"}
    end
  end

  defp validate_sandbox(_, _), do: :ok

  defp validate_file_size(file_path, max_size) do
    case File.stat(file_path) do
      {:ok, %{size: size}} when size <= max_size -> :ok
      {:ok, %{size: size}} -> {:error, "File too large: #{size} bytes"}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Otto.ToolBus Registry

The `Otto.ToolBus` is a GenServer that manages tool registration, discovery, and lifecycle.

### API Functions

#### Tool Registration

```elixir
@spec register_tool(module()) :: :ok | {:error, any()}
def register_tool(tool_module)
```

Register a tool module with the ToolBus. The module must implement the `Otto.Tool` behaviour.

**Example:**
```elixir
Otto.ToolBus.register_tool(MyApp.Tools.FileReader)
# => :ok

Otto.ToolBus.register_tool(NotATool)
# => {:error, "Module does not implement Otto.Tool behaviour"}
```

#### Tool Discovery

```elixir
@spec list_tools() :: [String.t()]
def list_tools()
```

Returns a list of all registered tool names.

**Example:**
```elixir
Otto.ToolBus.list_tools()
# => ["fs.read", "fs.write", "grep", "http.get", "test.run"]
```

```elixir
@spec get_tool(String.t()) :: {:ok, module()} | {:error, :not_found}
def get_tool(tool_name)
```

Get the module for a specific tool by name.

**Example:**
```elixir
Otto.ToolBus.get_tool("fs.read")
# => {:ok, Otto.Tools.FileSystem.Read}

Otto.ToolBus.get_tool("nonexistent")
# => {:error, :not_found}
```

#### Tool Information

```elixir
@spec tool_info(String.t()) :: {:ok, map()} | {:error, :not_found}
def tool_info(tool_name)
```

Get detailed information about a tool including permissions and schema.

**Example:**
```elixir
Otto.ToolBus.tool_info("fs.read")
# => {:ok, %{
#      name: "fs.read",
#      module: Otto.Tools.FileSystem.Read,
#      permissions: [:read],
#      schema: %{...}
#    }}
```

#### Tool Invocation

```elixir
@spec call_tool(String.t(), map(), Otto.ToolContext.t()) ::
  {:ok, any()} | {:error, any()}
def call_tool(tool_name, params, context)
```

Invoke a tool with parameters and context. Handles permission checking, parameter validation, and execution.

**Example:**
```elixir
context = %Otto.ToolContext{
  agent_id: "helper",
  working_dir: "/app",
  permissions: [:read, :write],
  sandbox: %{enabled: true, allowed_paths: ["/app"]}
}

Otto.ToolBus.call_tool("fs.read", %{"path" => "README.md"}, context)
# => {:ok, %{content: "# My Project\n...", path: "/app/README.md", size: 1024}}
```

#### Hot Reloading

```elixir
@spec reload_tool(String.t()) :: :ok | {:error, any()}
def reload_tool(tool_name)
```

Reload a tool module without restarting the system. Useful during development.

**Example:**
```elixir
Otto.ToolBus.reload_tool("fs.read")
# => :ok
```

## Built-in Tools

Otto Phase 0 includes several built-in tools for common operations:

### File System Tools

#### fs.read

Read file contents with size limits and sandbox enforcement.

**Permissions:** `[:read]`

**Parameters:**
- `path` (required): File path to read
- `max_size` (optional): Maximum file size in bytes (default: 2MB)

**Example:**
```elixir
Otto.ToolBus.call_tool("fs.read", %{
  "path" => "src/main.ex"
}, context)
# => {:ok, %{content: "defmodule...", path: "/app/src/main.ex", size: 256}}
```

#### fs.write

Write content to files with atomic operations and backup support.

**Permissions:** `[:write]`

**Parameters:**
- `path` (required): File path to write
- `content` (required): Content to write
- `backup` (optional): Create backup if file exists (default: true)
- `mode` (optional): File permissions (default: 0644)

**Example:**
```elixir
Otto.ToolBus.call_tool("fs.write", %{
  "path" => "output.txt",
  "content" => "Hello, Otto!",
  "backup" => true
}, context)
# => {:ok, %{path: "/app/output.txt", size: 12, backup_path: "/app/output.txt.bak"}}
```

### Search Tools

#### grep

Pattern search using ripgrep with timeout protection.

**Permissions:** `[:read]`

**Parameters:**
- `pattern` (required): Regular expression pattern
- `path` (optional): Search path (default: working directory)
- `max_results` (optional): Maximum results to return (default: 1000)
- `timeout_ms` (optional): Search timeout in milliseconds (default: 10000)
- `case_sensitive` (optional): Case sensitive search (default: true)

**Example:**
```elixir
Otto.ToolBus.call_tool("grep", %{
  "pattern" => "defmodule.*Agent",
  "path" => "lib/",
  "max_results" => 50
}, context)
# => {:ok, %{
#      results: [
#        %{file: "lib/agent.ex", line: 1, content: "defmodule Otto.Agent do", line_number: 1}
#      ],
#      total_matches: 1,
#      search_time_ms: 45
#    }}
```

### HTTP Tools

#### http.get

HTTP GET requests with timeout and domain allowlist.

**Permissions:** `[:network]`

**Parameters:**
- `url` (required): URL to request
- `headers` (optional): HTTP headers map
- `timeout_ms` (optional): Request timeout (default: 30000)
- `follow_redirects` (optional): Follow redirects (default: true)

**Example:**
```elixir
Otto.ToolBus.call_tool("http.get", %{
  "url" => "https://api.github.com/user",
  "headers" => %{"Authorization" => "token #{token}"}
}, context)
# => {:ok, %{
#      status: 200,
#      headers: %{...},
#      body: "{\"login\": \"user\", ...}",
#      response_time_ms: 234
#    }}
```

#### http.post

HTTP POST requests with JSON/form data support.

**Permissions:** `[:network]`

**Parameters:**
- `url` (required): URL to post to
- `body` (required): Request body (string or map)
- `headers` (optional): HTTP headers map
- `content_type` (optional): Content type (default: "application/json")
- `timeout_ms` (optional): Request timeout (default: 30000)

### Data Tools

#### json.parse

Parse JSON strings with schema validation.

**Permissions:** `[:read]`

**Parameters:**
- `json` (required): JSON string to parse
- `schema` (optional): JSON schema for validation

**Example:**
```elixir
Otto.ToolBus.call_tool("json.parse", %{
  "json" => "{\"name\": \"Otto\", \"version\": \"0.1.0\"}"
}, context)
# => {:ok, %{name: "Otto", version: "0.1.0"}}
```

#### yaml.parse

Parse YAML strings with validation support.

**Permissions:** `[:read]`

**Parameters:**
- `yaml` (required): YAML string to parse
- `schema` (optional): Schema for validation

### Test Tools

#### test.run

Execute `mix test` with structured output parsing.

**Permissions:** `[:exec]`

**Parameters:**
- `path` (optional): Test path/pattern (default: all tests)
- `timeout_ms` (optional): Test timeout (default: 60000)
- `env` (optional): Environment variables map

**Example:**
```elixir
Otto.ToolBus.call_tool("test.run", %{
  "path" => "test/agent_test.exs",
  "timeout_ms" => 30000
}, context)
# => {:ok, %{
#      passed: 12,
#      failed: 0,
#      skipped: 0,
#      duration_ms: 2341,
#      failures: []
#    }}
```

## Custom Tool Development

### Step 1: Implement the Otto.Tool Behaviour

```elixir
defmodule MyApp.Tools.SlackNotifier do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "slack.notify"

  @impl Otto.Tool
  def permissions, do: [:network]

  @impl Otto.Tool
  def call(%{"message" => message} = params, context) do
    webhook_url = System.get_env("SLACK_WEBHOOK_URL")

    body = %{
      text: message,
      channel: params["channel"] || "#general",
      username: "Otto Agent"
    }

    case HTTPoison.post(webhook_url, Jason.encode!(body), [
      {"Content-Type", "application/json"}
    ]) do
      {:ok, %{status_code: 200}} ->
        {:ok, %{sent: true, message: message}}
      {:ok, %{status_code: code}} ->
        {:error, "Slack API returned status #{code}"}
      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @impl Otto.Tool
  def validate_params(%{"message" => msg}) when is_binary(msg), do: :ok
  def validate_params(_), do: {:error, "message parameter is required"}

  @impl Otto.Tool
  def param_schema do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{
          "type" => "string",
          "description" => "Message to send to Slack"
        },
        "channel" => %{
          "type" => "string",
          "description" => "Slack channel (default: #general)"
        }
      },
      "required" => ["message"]
    }
  end
end
```

### Step 2: Register Your Tool

```elixir
# In your application startup
Otto.ToolBus.register_tool(MyApp.Tools.SlackNotifier)
```

### Step 3: Configure Agent to Use Tool

```yaml
# .otto/agents/notifier.yml
name: "slack_notifier"
tools:
  - "slack.notify"
  - "fs.read"
tool_config:
  slack.notify:
    default_channel: "#alerts"
```

### Step 4: Test Your Tool

```elixir
defmodule MyApp.Tools.SlackNotifierTest do
  use ExUnit.Case

  describe "SlackNotifier tool" do
    setup do
      context = %Otto.ToolContext{
        agent_id: "test",
        working_dir: "/tmp",
        permissions: [:network]
      }

      {:ok, context: context}
    end

    test "sends notification successfully", %{context: context} do
      params = %{"message" => "Test notification"}

      assert {:ok, result} = MyApp.Tools.SlackNotifier.call(params, context)
      assert result.sent == true
      assert result.message == "Test notification"
    end

    test "validates required parameters", %{context: context} do
      assert {:error, _} = MyApp.Tools.SlackNotifier.call(%{}, context)
    end
  end
end
```

## Permission Model

Tools declare the permissions they need to function. Agents must be configured with appropriate permissions to use tools.

### Available Permissions

- **`:read`** - File system reads, data parsing
- **`:write`** - File system writes, data persistence
- **`:exec`** - Shell command execution, process spawning
- **`:network`** - HTTP requests, external API calls

### Permission Enforcement

Permission checking occurs at multiple levels:

1. **Tool Registration**: Tools declare required permissions
2. **Agent Configuration**: Agents specify allowed permissions
3. **Runtime Checking**: ToolBus validates permissions before execution

```elixir
# Agent configuration
budgets:
  permissions: [:read, :write]  # Agent can only use read/write tools

# Tool that requires network access will fail
Otto.ToolBus.call_tool("http.get", params, context)
# => {:error, "Tool requires :network permission but agent only has [:read, :write]"}
```

### Sandbox Enforcement

When sandbox mode is enabled, tools are restricted to specific paths:

```elixir
context = %Otto.ToolContext{
  sandbox: %{
    enabled: true,
    allowed_paths: ["/app/src", "/app/test"],
    denied_patterns: ["**/*.secret", ".env*"]
  }
}

# This will succeed
Otto.ToolBus.call_tool("fs.read", %{"path" => "/app/src/main.ex"}, context)

# This will fail
Otto.ToolBus.call_tool("fs.read", %{"path" => "/etc/passwd"}, context)
# => {:error, "File access denied by sandbox: /etc/passwd"}
```

## Tool Context

The `Otto.ToolContext` struct provides tools with runtime information:

```elixir
defmodule Otto.ToolContext do
  @type t :: %__MODULE__{
    agent_id: String.t(),
    agent_config: Otto.Agent.Config.t(),
    working_dir: String.t(),
    permissions: [atom()],
    sandbox: map() | nil,
    budget_guard: pid() | nil,
    correlation_id: String.t(),
    metadata: map()
  }

  defstruct [
    :agent_id,
    :agent_config,
    :working_dir,
    :permissions,
    :sandbox,
    :budget_guard,
    :correlation_id,
    metadata: %{}
  ]
end
```

### Using Context in Tools

```elixir
def call(params, %Otto.ToolContext{} = context) do
  # Access agent information
  Logger.info("Tool called by agent #{context.agent_id}")

  # Check permissions
  if :network in context.permissions do
    make_http_request(params)
  else
    {:error, "Network permission required"}
  end

  # Use working directory
  file_path = Path.expand(params["path"], context.working_dir)

  # Add metadata
  result = %{
    data: process_data(params),
    agent_id: context.agent_id,
    correlation_id: context.correlation_id
  }

  {:ok, result}
end
```

## Error Handling

Tools should return consistent error responses:

### Error Response Format

```elixir
{:error, reason}
```

Where `reason` can be:
- String: Human-readable error message
- Map: Structured error with additional context
- Atom: Error type identifier

### Common Error Patterns

```elixir
# Permission denied
{:error, "Tool requires :network permission"}

# Invalid parameters
{:error, %{type: :validation_error, field: "path", message: "Path is required"}}

# Resource not found
{:error, :not_found}

# Timeout
{:error, %{type: :timeout, timeout_ms: 30000}}

# External service failure
{:error, %{type: :external_error, service: "slack", status: 429, message: "Rate limited"}}
```

### Error Recovery

Tools should implement appropriate error recovery:

```elixir
def call(params, context) do
  case external_service_call(params) do
    {:ok, result} ->
      {:ok, result}

    {:error, :rate_limited} ->
      # Wait and retry once
      Process.sleep(1000)
      external_service_call(params)

    {:error, :timeout} ->
      {:error, %{
        type: :timeout,
        message: "Service request timed out",
        retry_suggested: true
      }}

    {:error, reason} ->
      {:error, reason}
  end
end
```

## Testing Tools

### Unit Testing

Create focused tests for tool logic:

```elixir
defmodule Otto.Tools.FileSystem.ReadTest do
  use ExUnit.Case

  alias Otto.Tools.FileSystem.Read

  setup do
    # Create test files
    File.mkdir_p!("/tmp/otto_test")
    File.write!("/tmp/otto_test/sample.txt", "Hello, World!")

    context = %Otto.ToolContext{
      working_dir: "/tmp/otto_test",
      permissions: [:read],
      sandbox: %{enabled: false}
    }

    on_exit(fn ->
      File.rm_rf("/tmp/otto_test")
    end)

    {:ok, context: context}
  end

  test "reads existing file", %{context: context} do
    params = %{"path" => "sample.txt"}

    assert {:ok, result} = Read.call(params, context)
    assert result.content == "Hello, World!"
    assert result.size == 13
  end

  test "returns error for missing file", %{context: context} do
    params = %{"path" => "missing.txt"}

    assert {:error, error} = Read.call(params, context)
    assert error =~ "File not found"
  end
end
```

### Integration Testing

Test tools within the ToolBus registry:

```elixir
defmodule Otto.ToolBusIntegrationTest do
  use ExUnit.Case

  setup do
    {:ok, _} = Otto.ToolBus.start_link([])
    Otto.ToolBus.register_tool(Otto.Tools.FileSystem.Read)

    context = %Otto.ToolContext{
      working_dir: "/tmp",
      permissions: [:read, :write, :exec, :network]
    }

    {:ok, context: context}
  end

  test "tool registration and invocation", %{context: context} do
    # Verify tool is registered
    assert "fs.read" in Otto.ToolBus.list_tools()

    # Create test file
    File.write!("/tmp/test.txt", "Test content")

    # Call tool through ToolBus
    params = %{"path" => "/tmp/test.txt"}
    assert {:ok, result} = Otto.ToolBus.call_tool("fs.read", params, context)
    assert result.content == "Test content"

    # Clean up
    File.rm("/tmp/test.txt")
  end
end
```

### Property-Based Testing

Use StreamData for property-based testing:

```elixir
defmodule Otto.Tools.JSONParsePropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Otto.Tools.JSON.Parse

  property "parsing and encoding are inverse operations" do
    check all data <- term() do
      json_string = Jason.encode!(data)
      params = %{"json" => json_string}
      context = %Otto.ToolContext{}

      assert {:ok, parsed} = Parse.call(params, context)
      assert parsed == data
    end
  end
end
```

---

This documentation provides a complete reference for working with Otto's tool system. For more examples and advanced usage patterns, see the [Getting Started Guide](getting-started.md) and [Examples Directory](../examples/).