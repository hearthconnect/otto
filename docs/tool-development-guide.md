# Otto Tool Development Guide

This comprehensive guide covers developing custom tools for Otto, including the permission model, security considerations, testing strategies, and advanced patterns. By the end, you'll be able to create production-ready tools that integrate seamlessly with the Otto ecosystem.

## Table of Contents

1. [Tool Development Overview](#tool-development-overview)
2. [Permission Model Deep Dive](#permission-model-deep-dive)
3. [Implementing Custom Tools](#implementing-custom-tools)
4. [Security Best Practices](#security-best-practices)
5. [Testing Tools](#testing-tools)
6. [Advanced Patterns](#advanced-patterns)
7. [Tool Registration & Discovery](#tool-registration--discovery)
8. [Performance Optimization](#performance-optimization)
9. [Real-world Examples](#real-world-examples)
10. [Publishing Tools](#publishing-tools)

## Tool Development Overview

Tools in Otto are discrete capabilities that agents can invoke to interact with external systems, perform computations, or manipulate data. They follow a well-defined contract and integrate with Otto's security, observability, and error handling systems.

### Tool Architecture

```
Otto.Tool Behaviour
├── Core Interface
│   ├── name/0           # Tool identifier
│   ├── permissions/0    # Required permissions
│   └── call/2          # Main execution function
├── Optional Interface
│   ├── validate_params/1  # Parameter validation
│   └── param_schema/0     # JSON schema for docs
├── Security Layer
│   ├── Permission checking
│   ├── Sandbox enforcement
│   └── Resource limits
└── Observability
    ├── Telemetry events
    ├── Error tracking
    └── Performance metrics
```

### Tool Lifecycle

1. **Development** - Implement Otto.Tool behaviour
2. **Registration** - Register with Otto.ToolBus
3. **Discovery** - Agents discover available tools
4. **Validation** - Parameters and permissions validated
5. **Execution** - Tool logic runs with context
6. **Result** - Success/error result returned
7. **Cleanup** - Resources cleaned up

### Design Principles

- **Single Responsibility** - Each tool has one clear purpose
- **Stateless** - Tools don't maintain state between calls
- **Idempotent** - Safe to retry tool operations
- **Secure by Default** - Minimal permissions, maximum safety
- **Observable** - Rich telemetry and error information

## Permission Model Deep Dive

Otto's permission system provides fine-grained control over what tools can do, ensuring agents operate within safe boundaries.

### Permission Types

```elixir
@type permission :: :read | :write | :exec | :network

# Permission hierarchy (from least to most privileged)
:read     # File reads, data parsing, queries
:write    # File writes, data mutations, persistence
:exec     # Process execution, shell commands
:network  # Network requests, external APIs
```

### Permission Inheritance

Some operations require multiple permissions:

```elixir
# File operations
"fs.read"    => [:read]
"fs.write"   => [:write]
"fs.copy"    => [:read, :write]
"fs.execute" => [:exec]

# Network operations
"http.get"   => [:network]
"http.post"  => [:network]
"ftp.upload" => [:network, :write]

# Database operations
"db.select"  => [:read]
"db.insert"  => [:write]
"db.backup"  => [:read, :write]
"db.restore" => [:write, :exec]
```

### Permission Enforcement Layers

#### 1. Declaration Level

Tools declare required permissions:

```elixir
defmodule MyApp.Tools.DatabaseQuery do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def permissions, do: [:read]  # Declares read permission requirement
end
```

#### 2. Agent Configuration Level

Agents specify allowed permissions:

```yaml
# .otto/agents/readonly_helper.yml
permissions:
  - read                    # Only read operations allowed

tools:
  - "fs.read"              # ✓ Compatible (requires :read)
  - "fs.write"             # ✗ Incompatible (requires :write)
```

#### 3. Runtime Enforcement Level

Otto.ToolBus validates permissions before execution:

```elixir
def call_tool(tool_name, params, context) do
  with {:ok, tool_module} <- get_tool(tool_name),
       :ok <- validate_permissions(tool_module, context.permissions),
       :ok <- validate_sandbox(tool_name, params, context) do
    tool_module.call(params, context)
  else
    {:error, :permission_denied} ->
      {:error, "Tool #{tool_name} requires permissions not granted to agent"}
    error ->
      error
  end
end
```

### Permission Validation Examples

```elixir
# Agent with read permission trying network tool
context = %Otto.ToolContext{permissions: [:read]}
Otto.ToolBus.call_tool("http.get", %{"url" => "https://example.com"}, context)
# => {:error, "Tool http.get requires [:network] permission but agent only has [:read]"}

# Agent with appropriate permissions
context = %Otto.ToolContext{permissions: [:read, :network]}
Otto.ToolBus.call_tool("http.get", %{"url" => "https://example.com"}, context)
# => {:ok, %{status: 200, body: "...", ...}}
```

### Designing Permission-Aware Tools

```elixir
defmodule MyApp.Tools.FileManager do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "file_manager"

  @impl Otto.Tool
  def permissions do
    # Tool requires multiple permissions for different operations
    [:read, :write]
  end

  @impl Otto.Tool
  def call(%{"operation" => "read"} = params, context) do
    # Check if specific operation is allowed
    if :read in context.permissions do
      do_read(params, context)
    else
      {:error, "Read operation requires :read permission"}
    end
  end

  def call(%{"operation" => "write"} = params, context) do
    if :write in context.permissions do
      do_write(params, context)
    else
      {:error, "Write operation requires :write permission"}
    end
  end

  def call(%{"operation" => "copy"} = params, context) do
    # Copy requires both read and write
    required = [:read, :write]
    if Enum.all?(required, &(&1 in context.permissions)) do
      do_copy(params, context)
    else
      missing = required -- context.permissions
      {:error, "Copy operation requires #{inspect(missing)} permissions"}
    end
  end
end
```

## Implementing Custom Tools

Let's walk through implementing several types of custom tools:

### Example 1: Simple Data Processing Tool

```elixir
defmodule MyApp.Tools.TextProcessor do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "text.process"

  @impl Otto.Tool
  def permissions, do: [:read]  # Only needs read permission

  @impl Otto.Tool
  def call(%{"text" => text, "operation" => operation} = params, _context) do
    case operation do
      "uppercase" ->
        {:ok, %{result: String.upcase(text)}}

      "lowercase" ->
        {:ok, %{result: String.downcase(text)}}

      "word_count" ->
        word_count = text |> String.split() |> length()
        char_count = String.length(text)
        {:ok, %{words: word_count, characters: char_count}}

      "reverse" ->
        {:ok, %{result: String.reverse(text)}}

      "extract_emails" ->
        email_regex = ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
        emails = Regex.scan(email_regex, text) |> Enum.map(&List.first/1)
        {:ok, %{emails: emails, count: length(emails)}}

      operation ->
        {:error, "Unsupported operation: #{operation}"}
    end
  end

  @impl Otto.Tool
  def validate_params(%{"text" => text, "operation" => op})
      when is_binary(text) and is_binary(op), do: :ok
  def validate_params(_), do: {:error, "text and operation parameters required"}

  @impl Otto.Tool
  def param_schema do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{
          "type" => "string",
          "description" => "Text to process"
        },
        "operation" => %{
          "type" => "string",
          "enum" => ["uppercase", "lowercase", "word_count", "reverse", "extract_emails"],
          "description" => "Processing operation to perform"
        }
      },
      "required" => ["text", "operation"]
    }
  end
end
```

### Example 2: Database Integration Tool

```elixir
defmodule MyApp.Tools.Database do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "database"

  @impl Otto.Tool
  def permissions, do: [:read, :write]  # Needs both for full functionality

  @impl Otto.Tool
  def call(%{"query" => query, "params" => params} = request, context) do
    operation_type = detect_operation_type(query)

    # Check permissions based on operation
    case validate_operation_permissions(operation_type, context.permissions) do
      :ok ->
        execute_query(query, params, context)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      {:error, %{
        type: :database_error,
        message: Exception.message(exception),
        query: query
      }}
  end

  defp detect_operation_type(query) do
    query_upper = String.upcase(String.trim(query))

    cond do
      String.starts_with?(query_upper, "SELECT") -> :read
      String.starts_with?(query_upper, "INSERT") -> :write
      String.starts_with?(query_upper, "UPDATE") -> :write
      String.starts_with?(query_upper, "DELETE") -> :write
      String.starts_with?(query_upper, "CREATE") -> :write
      String.starts_with?(query_upper, "DROP") -> :write
      String.starts_with?(query_upper, "ALTER") -> :write
      true -> :unknown
    end
  end

  defp validate_operation_permissions(operation_type, agent_permissions) do
    case operation_type do
      :read ->
        if :read in agent_permissions do
          :ok
        else
          {:error, "SELECT queries require :read permission"}
        end

      :write ->
        if :write in agent_permissions do
          :ok
        else
          {:error, "Data modification queries require :write permission"}
        end

      :unknown ->
        {:error, "Unknown query type - permissions cannot be validated"}
    end
  end

  defp execute_query(query, params, context) do
    # Use application's Repo
    case MyApp.Repo.query(query, params) do
      {:ok, %Postgrex.Result{} = result} ->
        # Convert to more friendly format
        {:ok, %{
          rows: result.rows,
          columns: result.columns,
          num_rows: result.num_rows,
          agent_id: context.agent_id,
          executed_at: DateTime.utc_now()
        }}

      {:error, %Postgrex.Error{} = error} ->
        {:error, %{
          type: :postgres_error,
          message: error.message,
          postgres_code: error.postgres.code
        }}
    end
  end

  @impl Otto.Tool
  def validate_params(%{"query" => query}) when is_binary(query), do: :ok
  def validate_params(_), do: {:error, "query parameter is required"}

  @impl Otto.Tool
  def param_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "SQL query to execute"
        },
        "params" => %{
          "type" => "array",
          "items" => %{"type" => ["string", "number", "boolean", "null"]},
          "description" => "Query parameters",
          "default" => []
        }
      },
      "required" => ["query"]
    }
  end
end
```

### Example 3: External API Tool with Advanced Features

```elixir
defmodule MyApp.Tools.SlackIntegration do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "slack"

  @impl Otto.Tool
  def permissions, do: [:network]

  @impl Otto.Tool
  def call(%{"action" => action} = params, context) do
    case action do
      "send_message" ->
        send_message(params, context)

      "list_channels" ->
        list_channels(params, context)

      "upload_file" ->
        upload_file(params, context)

      "get_user_info" ->
        get_user_info(params, context)

      _ ->
        {:error, "Unknown action: #{action}"}
    end
  end

  defp send_message(%{"channel" => channel, "text" => text} = params, context) do
    webhook_url = get_webhook_url(params)

    message = %{
      channel: channel,
      text: text,
      username: "Otto Agent",
      icon_emoji: ":robot_face:",
      attachments: build_attachments(params, context)
    }

    case make_slack_request(:post, webhook_url, message) do
      {:ok, _response} ->
        {:ok, %{
          sent: true,
          channel: channel,
          message: text,
          timestamp: DateTime.utc_now()
        }}

      {:error, reason} ->
        {:error, %{
          type: :slack_api_error,
          reason: reason,
          action: "send_message"
        }}
    end
  end

  defp list_channels(_params, _context) do
    token = get_bot_token()
    url = "https://slack.com/api/conversations.list"

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "channels" => channels}} ->
            formatted_channels =
              Enum.map(channels, fn channel ->
                %{
                  id: channel["id"],
                  name: channel["name"],
                  is_channel: channel["is_channel"],
                  is_private: channel["is_private"],
                  is_member: channel["is_member"]
                }
              end)

            {:ok, %{channels: formatted_channels, count: length(formatted_channels)}}

          {:ok, %{"ok" => false, "error" => error}} ->
            {:error, "Slack API error: #{error}"}

          {:error, _} ->
            {:error, "Failed to parse Slack API response"}
        end

      {:ok, %{status_code: status}} ->
        {:error, "Slack API returned status #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP request failed: #{reason}"}
    end
  end

  defp upload_file(%{"file_path" => file_path, "channel" => channel} = params, context) do
    # Check if file exists and is within sandbox
    case validate_file_access(file_path, context) do
      :ok ->
        do_upload_file(file_path, channel, params, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_upload_file(file_path, channel, params, context) do
    token = get_bot_token()
    url = "https://slack.com/api/files.upload"

    multipart = [
      {"token", token},
      {"channels", channel},
      {"title", params["title"] || Path.basename(file_path)},
      {"initial_comment", params["comment"] || "File uploaded by Otto Agent"},
      {:file, file_path}
    ]

    case HTTPoison.post(url, {:multipart, multipart}) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "file" => file_info}} ->
            {:ok, %{
              uploaded: true,
              file_id: file_info["id"],
              url: file_info["url_private"],
              size: file_info["size"]
            }}

          {:ok, %{"ok" => false, "error" => error}} ->
            {:error, "File upload failed: #{error}"}
        end

      {:ok, %{status_code: status}} ->
        {:error, "Upload request returned status #{status}"}

      {:error, reason} ->
        {:error, "Upload request failed: #{inspect(reason)}"}
    end
  end

  defp validate_file_access(file_path, %{sandbox: nil}), do: :ok

  defp validate_file_access(file_path, %{sandbox: %{enabled: false}}), do: :ok

  defp validate_file_access(file_path, context) do
    full_path = Path.expand(file_path, context.working_dir)

    # Check allowed paths
    allowed = Enum.any?(context.sandbox.allowed_paths, fn allowed_path ->
      String.starts_with?(full_path, allowed_path)
    end)

    if allowed do
      # Check denied patterns
      denied = Enum.any?(context.sandbox.denied_patterns, fn pattern ->
        Path.wildcard(pattern) |> Enum.member?(full_path)
      end)

      if denied do
        {:error, "File access denied by sandbox pattern"}
      else
        :ok
      end
    else
      {:error, "File access denied by sandbox"}
    end
  end

  defp build_attachments(params, context) do
    attachments = []

    # Add agent context if requested
    if params["include_context"] do
      context_attachment = %{
        color: "good",
        title: "Agent Context",
        fields: [
          %{title: "Agent ID", value: context.agent_id, short: true},
          %{title: "Correlation ID", value: context.correlation_id, short: true}
        ]
      }

      attachments = [context_attachment | attachments]
    end

    # Add custom attachments
    custom_attachments = Map.get(params, "attachments", [])
    attachments ++ custom_attachments
  end

  defp make_slack_request(method, url, body) do
    headers = [{"Content-Type", "application/json"}]
    encoded_body = Jason.encode!(body)

    case HTTPoison.request(method, url, encoded_body, headers, timeout: 30_000) do
      {:ok, %{status_code: 200}} -> {:ok, :sent}
      {:ok, %{status_code: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_webhook_url(params) do
    # Priority: params > context config > env var
    params["webhook_url"] ||
      Application.get_env(:my_app, :slack_webhook_url) ||
      System.get_env("SLACK_WEBHOOK_URL")
  end

  defp get_bot_token do
    Application.get_env(:my_app, :slack_bot_token) ||
      System.get_env("SLACK_BOT_TOKEN")
  end

  @impl Otto.Tool
  def validate_params(%{"action" => action} = params) do
    case action do
      "send_message" ->
        validate_send_message_params(params)

      "list_channels" ->
        :ok

      "upload_file" ->
        validate_upload_file_params(params)

      "get_user_info" ->
        validate_get_user_info_params(params)

      _ ->
        {:error, "Unknown action: #{action}"}
    end
  end

  def validate_params(_), do: {:error, "action parameter is required"}

  defp validate_send_message_params(%{"channel" => ch, "text" => txt})
       when is_binary(ch) and is_binary(txt), do: :ok
  defp validate_send_message_params(_), do: {:error, "channel and text required for send_message"}

  defp validate_upload_file_params(%{"file_path" => path, "channel" => ch})
       when is_binary(path) and is_binary(ch), do: :ok
  defp validate_upload_file_params(_), do: {:error, "file_path and channel required for upload_file"}

  defp validate_get_user_info_params(%{"user_id" => uid})
       when is_binary(uid), do: :ok
  defp validate_get_user_info_params(_), do: {:error, "user_id required for get_user_info"}

  @impl Otto.Tool
  def param_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["send_message", "list_channels", "upload_file", "get_user_info"]
        },
        "channel" => %{
          "type" => "string",
          "description" => "Slack channel name or ID"
        },
        "text" => %{
          "type" => "string",
          "description" => "Message text to send"
        },
        "file_path" => %{
          "type" => "string",
          "description" => "Path to file to upload"
        },
        "user_id" => %{
          "type" => "string",
          "description" => "Slack user ID"
        },
        "webhook_url" => %{
          "type" => "string",
          "description" => "Override webhook URL"
        },
        "include_context" => %{
          "type" => "boolean",
          "description" => "Include agent context in message"
        }
      },
      "required" => ["action"]
    }
  end
end
```

## Security Best Practices

### 1. Input Validation

Always validate and sanitize inputs:

```elixir
defmodule MyApp.Tools.SecureFileReader do
  @behaviour Otto.Tool

  def call(%{"path" => path} = params, context) do
    with :ok <- validate_path_format(path),
         :ok <- validate_path_safety(path),
         :ok <- validate_sandbox_access(path, context),
         :ok <- validate_file_size(path, params["max_size"]) do
      File.read(path)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_path_format(path) when is_binary(path) do
    # Check for path traversal attempts
    if String.contains?(path, ["../", "..\\", "~/"]) do
      {:error, "Path traversal detected"}
    else
      :ok
    end
  end

  defp validate_path_format(_), do: {:error, "Path must be a string"}

  defp validate_path_safety(path) do
    # Resolve to absolute path to prevent confusion
    abs_path = Path.expand(path)

    # Check for suspicious paths
    dangerous_patterns = [
      "/etc/",
      "/proc/",
      "/sys/",
      "/dev/",
      ".ssh/",
      ".aws/",
      ".env"
    ]

    if Enum.any?(dangerous_patterns, &String.contains?(abs_path, &1)) do
      {:error, "Access to system paths not allowed"}
    else
      :ok
    end
  end
end
```

### 2. Sandbox Enforcement

Respect sandbox boundaries:

```elixir
defmodule Otto.Tools.SandboxHelpers do
  def validate_path_access(path, context) do
    case context.sandbox do
      nil ->
        :ok  # No sandbox

      %{enabled: false} ->
        :ok  # Sandbox disabled

      %{enabled: true} = sandbox ->
        enforce_sandbox(path, sandbox, context.working_dir)
    end
  end

  defp enforce_sandbox(path, sandbox, working_dir) do
    abs_path = Path.expand(path, working_dir)

    with :ok <- check_allowed_paths(abs_path, sandbox.allowed_paths),
         :ok <- check_denied_patterns(abs_path, sandbox.denied_patterns) do
      :ok
    end
  end

  defp check_allowed_paths(abs_path, allowed_paths) do
    if Enum.any?(allowed_paths, &String.starts_with?(abs_path, &1)) do
      :ok
    else
      {:error, "Path not in allowed sandbox paths: #{abs_path}"}
    end
  end

  defp check_denied_patterns(abs_path, denied_patterns) do
    if Enum.any?(denied_patterns, &path_matches_pattern?(abs_path, &1)) do
      {:error, "Path matches denied pattern: #{abs_path}"}
    else
      :ok
    end
  end

  defp path_matches_pattern?(path, pattern) do
    # Use Path.wildcard for glob pattern matching
    pattern
    |> Path.wildcard()
    |> Enum.member?(path)
  end
end
```

### 3. Resource Limits

Implement proper resource limits:

```elixir
defmodule MyApp.Tools.SafeHttpClient do
  @behaviour Otto.Tool

  # Maximum response size (10MB)
  @max_response_size 10 * 1024 * 1024

  def call(%{"url" => url} = params, context) do
    timeout = min(params["timeout_ms"] || 30_000, 300_000)  # Max 5 minutes

    options = [
      timeout: timeout,
      recv_timeout: timeout,
      max_body_length: @max_response_size,
      follow_redirect: false  # Explicit redirect handling
    ]

    case HTTPoison.get(url, [], options) do
      {:ok, %{status_code: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, body: body, size: byte_size(body)}}

      {:ok, %{status_code: status}} ->
        {:error, "HTTP request returned status #{status}"}

      {:error, %HTTPoison.Error{reason: :timeout}} ->
        {:error, "Request timeout after #{timeout}ms"}

      {:error, %HTTPoison.Error{reason: :req_timedout}} ->
        {:error, "Request timeout"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end
end
```

### 4. Secrets Management

Never expose secrets in tool output:

```elixir
defmodule MyApp.Tools.SecureApiClient do
  def call(params, context) do
    api_key = get_api_key()

    if api_key do
      make_authenticated_request(params, api_key)
    else
      {:error, "API key not configured"}
    end
  end

  defp get_api_key do
    # Priority: environment variable > application config
    System.get_env("API_KEY") ||
      Application.get_env(:my_app, :api_key)
  end

  defp make_authenticated_request(params, api_key) do
    # Make request but scrub sensitive data from response
    case do_http_request(params, api_key) do
      {:ok, response} ->
        {:ok, scrub_sensitive_data(response)}

      {:error, reason} ->
        {:error, scrub_error_message(reason)}
    end
  end

  defp scrub_sensitive_data(response) do
    response
    |> Map.update("headers", %{}, &scrub_headers/1)
    |> Map.update("body", "", &scrub_body/1)
  end

  defp scrub_headers(headers) do
    # Remove sensitive headers
    sensitive_keys = ["authorization", "x-api-key", "cookie", "set-cookie"]

    headers
    |> Enum.reject(fn {key, _} -> String.downcase(key) in sensitive_keys end)
    |> Map.new()
  end

  defp scrub_body(body) do
    # Remove sensitive patterns from response body
    body
    |> String.replace(~r/api[_-]?key[\":\s]+[\w\-]+/i, "api_key: [REDACTED]")
    |> String.replace(~r/token[\":\s]+[\w\-\.]+/i, "token: [REDACTED]")
    |> String.replace(~r/password[\":\s]+\w+/i, "password: [REDACTED]")
  end

  defp scrub_error_message(reason) do
    # Ensure error messages don't leak sensitive info
    reason
    |> to_string()
    |> String.replace(~r/api[_-]?key[=\s][\w\-]+/i, "api_key=[REDACTED]")
    |> String.replace(~r/token[=\s][\w\-\.]+/i, "token=[REDACTED]")
  end
end
```

## Testing Tools

Comprehensive testing ensures tools work correctly and safely:

### 1. Unit Tests

```elixir
defmodule MyApp.Tools.TextProcessorTest do
  use ExUnit.Case

  alias MyApp.Tools.TextProcessor

  describe "TextProcessor tool" do
    test "returns correct tool name" do
      assert TextProcessor.name() == "text.process"
    end

    test "declares read permission" do
      assert TextProcessor.permissions() == [:read]
    end

    test "validates parameters correctly" do
      valid_params = %{"text" => "hello", "operation" => "uppercase"}
      assert TextProcessor.validate_params(valid_params) == :ok

      invalid_params = %{"text" => "hello"}  # missing operation
      assert {:error, _} = TextProcessor.validate_params(invalid_params)
    end

    test "uppercase operation works" do
      params = %{"text" => "hello world", "operation" => "uppercase"}
      context = %Otto.ToolContext{}

      assert {:ok, %{result: "HELLO WORLD"}} = TextProcessor.call(params, context)
    end

    test "word count operation works" do
      params = %{"text" => "hello world test", "operation" => "word_count"}
      context = %Otto.ToolContext{}

      assert {:ok, %{words: 3, characters: 16}} = TextProcessor.call(params, context)
    end

    test "email extraction works" do
      text = "Contact us at support@example.com or admin@test.org"
      params = %{"text" => text, "operation" => "extract_emails"}
      context = %Otto.ToolContext{}

      assert {:ok, %{emails: emails, count: 2}} = TextProcessor.call(params, context)
      assert "support@example.com" in emails
      assert "admin@test.org" in emails
    end

    test "handles invalid operation" do
      params = %{"text" => "hello", "operation" => "invalid_op"}
      context = %Otto.ToolContext{}

      assert {:error, "Unsupported operation: invalid_op"} = TextProcessor.call(params, context)
    end
  end
end
```

### 2. Integration Tests

```elixir
defmodule MyApp.Tools.SlackIntegrationTest do
  use ExUnit.Case

  import Mox

  alias MyApp.Tools.SlackIntegration

  # Mock HTTP client
  setup :verify_on_exit!

  describe "SlackIntegration tool with mocked HTTP" do
    test "sends message successfully" do
      # Mock successful webhook response
      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 200, body: "ok"}}
      end)

      params = %{
        "action" => "send_message",
        "channel" => "#general",
        "text" => "Hello from Otto!",
        "webhook_url" => "https://hooks.slack.com/test"
      }

      context = %Otto.ToolContext{
        agent_id: "test_agent",
        correlation_id: "test_123"
      }

      assert {:ok, result} = SlackIntegration.call(params, context)
      assert result.sent == true
      assert result.channel == "#general"
    end

    test "handles webhook failure" do
      expect(HTTPoisonMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 400, body: "Bad Request"}}
      end)

      params = %{
        "action" => "send_message",
        "channel" => "#general",
        "text" => "Hello!",
        "webhook_url" => "https://hooks.slack.com/test"
      }

      context = %Otto.ToolContext{}

      assert {:error, %{type: :slack_api_error}} = SlackIntegration.call(params, context)
    end
  end
end
```

### 3. Property-Based Testing

```elixir
defmodule MyApp.Tools.FileManagerPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias MyApp.Tools.FileManager

  property "file paths are properly validated" do
    check all path <- string(:alphanumeric),
              operation <- member_of(["read", "write", "delete"]) do

      params = %{"path" => path, "operation" => operation}

      case FileManager.validate_params(params) do
        :ok ->
          # If validation passes, tool should not crash
          context = %Otto.ToolContext{
            working_dir: "/tmp/test",
            permissions: [:read, :write],
            sandbox: %{enabled: false}
          }

          # This should either succeed or fail gracefully
          case FileManager.call(params, context) do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end

        {:error, _} ->
          # Validation failed - this is fine
          :ok
      end
    end
  end

  property "sandbox violations are always caught" do
    check all path <- string(:ascii),
              enabled <- boolean() do

      # Create context with restrictive sandbox
      context = %Otto.ToolContext{
        working_dir: "/app",
        permissions: [:read],
        sandbox: %{
          enabled: enabled,
          allowed_paths: ["/app/safe"],
          denied_patterns: ["**/.secret"]
        }
      }

      params = %{"path" => path, "operation" => "read"}

      case FileManager.call(params, context) do
        {:ok, _} ->
          # If operation succeeded, path must be safe
          abs_path = Path.expand(path, context.working_dir)
          assert String.starts_with?(abs_path, "/app/safe")

        {:error, _} ->
          # Error is acceptable - might be sandbox violation or file not found
          :ok
      end
    end
  end
end
```

### 4. Security Testing

```elixir
defmodule MyApp.Tools.SecurityTest do
  use ExUnit.Case

  describe "path traversal protection" do
    test "blocks obvious path traversal attempts" do
      dangerous_paths = [
        "../../../etc/passwd",
        "..\\..\\windows\\system32",
        "~/secret_file",
        "/etc/shadow",
        "../.ssh/id_rsa"
      ]

      context = %Otto.ToolContext{
        working_dir: "/app",
        permissions: [:read],
        sandbox: %{
          enabled: true,
          allowed_paths: ["/app"],
          denied_patterns: []
        }
      }

      for path <- dangerous_paths do
        params = %{"path" => path, "operation" => "read"}
        assert {:error, _} = MyApp.Tools.FileManager.call(params, context),
               "Path traversal not blocked: #{path}"
      end
    end

    test "respects sandbox denied patterns" do
      sensitive_files = [
        ".env",
        "config/secrets.yml",
        "private_key.pem",
        ".aws/credentials"
      ]

      context = %Otto.ToolContext{
        working_dir: "/app",
        permissions: [:read],
        sandbox: %{
          enabled: true,
          allowed_paths: ["/app"],
          denied_patterns: ["**/.env*", "**/*.pem", "**/.aws/**", "**/secrets.*"]
        }
      }

      for file <- sensitive_files do
        params = %{"path" => file, "operation" => "read"}
        assert {:error, _} = MyApp.Tools.FileManager.call(params, context),
               "Sensitive file access not blocked: #{file}"
      end
    end
  end

  describe "permission enforcement" do
    test "blocks operations without required permissions" do
      # Agent with only read permission
      context = %Otto.ToolContext{
        permissions: [:read],
        sandbox: %{enabled: false}
      }

      write_params = %{"path" => "/tmp/test.txt", "operation" => "write", "content" => "test"}
      assert {:error, _} = MyApp.Tools.FileManager.call(write_params, context)

      exec_params = %{"command" => "ls", "operation" => "execute"}
      assert {:error, _} = MyApp.Tools.FileManager.call(exec_params, context)
    end

    test "allows operations with sufficient permissions" do
      context = %Otto.ToolContext{
        permissions: [:read, :write, :exec],
        sandbox: %{enabled: false}
      }

      # These should not fail due to permission issues (may fail for other reasons)
      read_params = %{"path" => "/tmp/nonexistent.txt", "operation" => "read"}
      case MyApp.Tools.FileManager.call(read_params, context) do
        {:error, reason} -> refute String.contains?(to_string(reason), "permission")
        {:ok, _} -> :ok
      end
    end
  end
end
```

## Advanced Patterns

### 1. Stateful Tools with Cleanup

```elixir
defmodule MyApp.Tools.DatabaseConnection do
  @behaviour Otto.Tool

  def call(%{"action" => "connect"} = params, context) do
    # Establish connection
    case establish_connection(params) do
      {:ok, conn} ->
        # Store connection in context metadata for cleanup
        store_connection(context.correlation_id, conn)
        {:ok, %{connected: true, connection_id: context.correlation_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def call(%{"action" => "query"} = params, context) do
    case get_connection(context.correlation_id) do
      {:ok, conn} ->
        execute_query(conn, params["query"], params["params"] || [])

      {:error, :not_connected} ->
        {:error, "Database not connected. Use connect action first."}
    end
  end

  def call(%{"action" => "disconnect"}, context) do
    case get_connection(context.correlation_id) do
      {:ok, conn} ->
        close_connection(conn)
        remove_connection(context.correlation_id)
        {:ok, %{disconnected: true}}

      {:error, :not_connected} ->
        {:ok, %{disconnected: true}}  # Already disconnected
    end
  end

  # Connection pool management
  defp store_connection(correlation_id, conn) do
    :ets.insert(:db_connections, {correlation_id, conn, :os.timestamp()})
  end

  defp get_connection(correlation_id) do
    case :ets.lookup(:db_connections, correlation_id) do
      [{^correlation_id, conn, _timestamp}] -> {:ok, conn}
      [] -> {:error, :not_connected}
    end
  end

  defp remove_connection(correlation_id) do
    :ets.delete(:db_connections, correlation_id)
  end

  # Cleanup process for orphaned connections
  def start_cleanup_process do
    spawn_link(fn -> cleanup_loop() end)
  end

  defp cleanup_loop do
    Process.sleep(60_000)  # Check every minute

    now = :os.timestamp()
    timeout = 600_000_000  # 10 minutes in microseconds

    # Find expired connections
    expired =
      :ets.tab2list(:db_connections)
      |> Enum.filter(fn {_id, _conn, timestamp} ->
        :timer.now_diff(now, timestamp) > timeout
      end)

    # Close expired connections
    Enum.each(expired, fn {correlation_id, conn, _} ->
      close_connection(conn)
      remove_connection(correlation_id)
    end)

    cleanup_loop()
  end
end
```

### 2. Tool Composition

```elixir
defmodule MyApp.Tools.FileAnalyzer do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "file_analyzer"

  @impl Otto.Tool
  def permissions, do: [:read]

  @impl Otto.Tool
  def call(%{"path" => path} = params, context) do
    with {:ok, content} <- read_file_safely(path, context),
         {:ok, analysis} <- analyze_content(content, params) do
      {:ok, analysis}
    end
  end

  defp read_file_safely(path, context) do
    # Delegate to fs.read tool for consistent behavior
    Otto.ToolBus.call_tool("fs.read", %{"path" => path}, context)
  end

  defp analyze_content(file_data, params) do
    content = file_data.content
    analysis = %{
      file_size: file_data.size,
      line_count: count_lines(content),
      word_count: count_words(content),
      character_count: String.length(content)
    }

    # Add language-specific analysis if requested
    analysis = if params["detect_language"] do
      Map.put(analysis, :language, detect_language(file_data.path, content))
    else
      analysis
    end

    # Add complexity metrics for code files
    analysis = if params["complexity_analysis"] do
      Map.put(analysis, :complexity, analyze_complexity(content))
    else
      analysis
    end

    {:ok, analysis}
  end

  defp count_lines(content) do
    content |> String.split("\n") |> length()
  end

  defp count_words(content) do
    content |> String.split() |> length()
  end

  defp detect_language(path, content) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".js" -> "javascript"
      ".py" -> "python"
      ".rb" -> "ruby"
      ".go" -> "go"
      _ -> detect_by_content(content)
    end
  end

  defp detect_by_content(content) do
    cond do
      String.contains?(content, "defmodule") -> "elixir"
      String.contains?(content, "function") and String.contains?(content, "var") -> "javascript"
      String.contains?(content, "def ") and String.contains?(content, "import") -> "python"
      true -> "unknown"
    end
  end

  defp analyze_complexity(content) do
    lines = String.split(content, "\n")

    %{
      cyclomatic_complexity: calculate_cyclomatic_complexity(lines),
      nesting_depth: calculate_max_nesting(lines),
      function_count: count_functions(lines)
    }
  end

  # Simplified complexity calculations
  defp calculate_cyclomatic_complexity(lines) do
    patterns = [~r/\bif\b/, ~r/\bcase\b/, ~r/\bwhen\b/, ~r/\bcond\b/, ~r/\btry\b/]

    Enum.reduce(lines, 1, fn line, acc ->
      matches = Enum.count(patterns, &Regex.match?(&1, line))
      acc + matches
    end)
  end

  defp calculate_max_nesting(lines) do
    lines
    |> Enum.reduce({0, 0}, fn line, {current_depth, max_depth} ->
      # Simple heuristic based on indentation
      indent_level = count_leading_spaces(line) |> div(2)
      new_max = max(max_depth, indent_level)
      {indent_level, new_max}
    end)
    |> elem(1)
  end

  defp count_functions(lines) do
    Enum.count(lines, fn line ->
      String.match?(line, ~r/^\s*def\s+\w+/)
    end)
  end

  defp count_leading_spaces(line) do
    line
    |> String.to_charlist()
    |> Enum.take_while(&(&1 == ?\s))
    |> length()
  end
end
```

### 3. Async Tool Operations

```elixir
defmodule MyApp.Tools.LongRunningProcessor do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "async_processor"

  @impl Otto.Tool
  def permissions, do: [:read, :write, :exec]

  @impl Otto.Tool
  def call(%{"operation" => "start_processing"} = params, context) do
    task_id = generate_task_id()

    # Start async task
    Task.start(fn ->
      process_data_async(params, context, task_id)
    end)

    {:ok, %{
      status: :started,
      task_id: task_id,
      message: "Processing started. Use check_status action to monitor progress."
    }}
  end

  def call(%{"operation" => "check_status", "task_id" => task_id}, _context) do
    case get_task_status(task_id) do
      {:ok, status} -> {:ok, status}
      {:error, :not_found} -> {:error, "Task not found: #{task_id}"}
    end
  end

  def call(%{"operation" => "cancel_task", "task_id" => task_id}, _context) do
    case cancel_task(task_id) do
      :ok -> {:ok, %{cancelled: true, task_id: task_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_data_async(params, context, task_id) do
    try do
      update_task_status(task_id, %{status: :processing, progress: 0})

      # Simulate long-running processing with progress updates
      total_steps = 100

      for step <- 1..total_steps do
        if task_cancelled?(task_id) do
          update_task_status(task_id, %{status: :cancelled, progress: step})
          exit(:cancelled)
        end

        # Simulate work
        Process.sleep(100)

        # Update progress
        progress = (step / total_steps * 100) |> round()
        update_task_status(task_id, %{status: :processing, progress: progress})
      end

      # Complete processing
      result = %{
        processed_items: total_steps,
        output_file: "/tmp/result_#{task_id}.json",
        duration_ms: 10_000
      }

      update_task_status(task_id, %{status: :completed, result: result, progress: 100})

    rescue
      exception ->
        error = %{
          type: :processing_error,
          message: Exception.message(exception),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        }

        update_task_status(task_id, %{status: :failed, error: error})
    end
  end

  defp generate_task_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp update_task_status(task_id, status) do
    updated_status = Map.put(status, :updated_at, DateTime.utc_now())
    :ets.insert(:async_tasks, {task_id, updated_status})
  end

  defp get_task_status(task_id) do
    case :ets.lookup(:async_tasks, task_id) do
      [{^task_id, status}] -> {:ok, status}
      [] -> {:error, :not_found}
    end
  end

  defp cancel_task(task_id) do
    case :ets.lookup(:async_tasks, task_id) do
      [{^task_id, %{status: :processing} = status}] ->
        cancelled_status = %{status | status: :cancelling}
        :ets.insert(:async_tasks, {task_id, cancelled_status})
        :ok

      [{^task_id, %{status: status}}] when status in [:completed, :failed, :cancelled] ->
        {:error, "Task already finished with status: #{status}"}

      [] ->
        {:error, :not_found}
    end
  end

  defp task_cancelled?(task_id) do
    case get_task_status(task_id) do
      {:ok, %{status: :cancelling}} -> true
      {:ok, %{status: :cancelled}} -> true
      _ -> false
    end
  end
end
```

## Tool Registration & Discovery

### Manual Registration

```elixir
# In your application startup
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      Otto.ToolBus,
      # ... other children
    ]

    # Register custom tools
    Otto.ToolBus.register_tool(MyApp.Tools.TextProcessor)
    Otto.ToolBus.register_tool(MyApp.Tools.DatabaseQuery)
    Otto.ToolBus.register_tool(MyApp.Tools.SlackIntegration)

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Auto-Discovery

```elixir
defmodule Otto.Tools.AutoDiscovery do
  @moduledoc """
  Automatically discovers and registers tools from specified modules.
  """

  def discover_and_register_tools(namespaces \\ [MyApp.Tools]) do
    namespaces
    |> Enum.flat_map(&find_tool_modules/1)
    |> Enum.each(&Otto.ToolBus.register_tool/1)
  end

  defp find_tool_modules(namespace) do
    # Get all modules under namespace
    Application.spec(:my_app)
    |> get_in([:modules])
    |> Enum.filter(fn module ->
      module_name = Atom.to_string(module)
      namespace_name = Atom.to_string(namespace)
      String.starts_with?(module_name, namespace_name)
    end)
    |> Enum.filter(&implements_otto_tool?/1)
  end

  defp implements_otto_tool?(module) do
    try do
      behaviours = module.__info__(:attributes)[:behaviour] || []
      Otto.Tool in behaviours
    rescue
      _ -> false
    end
  end
end

# Use in application startup
Otto.Tools.AutoDiscovery.discover_and_register_tools([MyApp.Tools, MyCompany.OttoTools])
```

### Hot Reloading During Development

```elixir
defmodule Otto.Tools.DevReloader do
  @moduledoc """
  Development helper for hot-reloading tools.
  """

  def reload_tool(tool_name) when is_binary(tool_name) do
    case Otto.ToolBus.get_tool(tool_name) do
      {:ok, module} ->
        reload_tool(module)

      {:error, :not_found} ->
        {:error, "Tool not found: #{tool_name}"}
    end
  end

  def reload_tool(module) when is_atom(module) do
    tool_name = module.name()

    # Recompile module
    case IEx.Helpers.r(module) do
      {:reloaded, ^module, _} ->
        # Re-register tool
        Otto.ToolBus.register_tool(module)
        {:ok, "Tool #{tool_name} reloaded successfully"}

      {:error, reason} ->
        {:error, "Failed to reload tool: #{reason}"}
    end
  end

  def watch_and_reload(modules) when is_list(modules) do
    # Simple file watcher for development
    spawn_link(fn ->
      watch_loop(modules)
    end)
  end

  defp watch_loop(modules) do
    # Check modification times
    Enum.each(modules, fn module ->
      if module_modified?(module) do
        reload_tool(module)
      end
    end)

    Process.sleep(1000)  # Check every second
    watch_loop(modules)
  end

  defp module_modified?(module) do
    # Simple modification time check
    # In production, use proper file watching library
    beam_file = :code.which(module)

    if beam_file != :non_existing do
      stat = File.stat!(beam_file)
      last_modified = Map.get(:persistent_term.get({__MODULE__, :last_modified}, %{}), module, ~N[1970-01-01 00:00:00])

      if NaiveDateTime.compare(stat.mtime, last_modified) == :gt do
        updated_times = Map.put(:persistent_term.get({__MODULE__, :last_modified}, %{}), module, stat.mtime)
        :persistent_term.put({__MODULE__, :last_modified}, updated_times)
        true
      else
        false
      end
    else
      false
    end
  end
end

# Usage in development
Otto.Tools.DevReloader.watch_and_reload([
  MyApp.Tools.TextProcessor,
  MyApp.Tools.DatabaseQuery
])
```

## Performance Optimization

### 1. Efficient Resource Usage

```elixir
defmodule MyApp.Tools.OptimizedFileProcessor do
  @behaviour Otto.Tool

  # Use streaming for large files
  def call(%{"path" => path, "operation" => "process_large_file"}, context) do
    case validate_file_access(path, context) do
      :ok ->
        process_file_streaming(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_file_streaming(path) do
    try do
      result =
        File.stream!(path, [:read], 8192)  # 8KB chunks
        |> Stream.map(&process_chunk/1)
        |> Enum.reduce(%{lines: 0, words: 0, chars: 0}, &merge_results/2)

      {:ok, result}
    rescue
      exception -> {:error, Exception.message(exception)}
    end
  end

  defp process_chunk(chunk) do
    %{
      lines: chunk |> String.split("\n") |> length() |> Kernel.-(1),
      words: chunk |> String.split() |> length(),
      chars: String.length(chunk)
    }
  end

  defp merge_results(chunk_result, accumulator) do
    %{
      lines: accumulator.lines + chunk_result.lines,
      words: accumulator.words + chunk_result.words,
      chars: accumulator.chars + chunk_result.chars
    }
  end
end
```

### 2. Caching Results

```elixir
defmodule MyApp.Tools.CachedApiClient do
  @behaviour Otto.Tool

  @cache_ttl 300_000  # 5 minutes

  def call(%{"url" => url} = params, context) do
    cache_key = build_cache_key(url, params)

    case get_cached_result(cache_key) do
      {:ok, cached_result} ->
        {:ok, Map.put(cached_result, :from_cache, true)}

      :miss ->
        case make_http_request(url, params) do
          {:ok, result} ->
            cache_result(cache_key, result)
            {:ok, Map.put(result, :from_cache, false)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp build_cache_key(url, params) do
    # Create stable cache key
    cache_data = %{url: url, headers: params["headers"], query: params["query"]}
    cache_string = Jason.encode!(cache_data)
    :crypto.hash(:sha256, cache_string) |> Base.encode16(case: :lower)
  end

  defp get_cached_result(cache_key) do
    case :ets.lookup(:http_cache, cache_key) do
      [{^cache_key, result, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, result}
        else
          :ets.delete(:http_cache, cache_key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_result(cache_key, result) do
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl
    :ets.insert(:http_cache, {cache_key, result, expires_at})
  end
end
```

### 3. Connection Pooling

```elixir
defmodule MyApp.Tools.PooledHttpClient do
  @behaviour Otto.Tool

  @pool_name :http_client_pool

  def start_link do
    # Start connection pool
    :hackney_pool.start_pool(@pool_name, [
      timeout: 30_000,
      max_connections: 100,
      pool_size: 20
    ])
  end

  def call(%{"url" => url} = params, context) do
    options = [
      pool: @pool_name,
      timeout: params["timeout"] || 30_000,
      recv_timeout: params["recv_timeout"] || 30_000
    ]

    case HTTPoison.get(url, headers(params), options) do
      {:ok, %{status_code: 200} = response} ->
        {:ok, %{
          status: response.status_code,
          headers: response.headers,
          body: response.body,
          pool_stats: get_pool_stats()
        }}

      {:ok, %{status_code: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_pool_stats do
    case :hackney_pool.get_stats(@pool_name) do
      {:ok, stats} -> stats
      _ -> %{}
    end
  end
end
```

## Real-world Examples

### Example 1: Code Quality Tool

```elixir
defmodule MyApp.Tools.CodeQualityAnalyzer do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "code_quality"

  @impl Otto.Tool
  def permissions, do: [:read, :exec]

  @impl Otto.Tool
  def call(%{"project_path" => path} = params, context) do
    analysis_results = %{}

    # Run multiple quality checks
    with {:ok, results} <- run_credo_analysis(path, context),
         analysis_results = Map.put(analysis_results, :credo, results),
         {:ok, results} <- run_dialyzer_analysis(path, context),
         analysis_results = Map.put(analysis_results, :dialyzer, results),
         {:ok, results} <- run_test_coverage(path, context),
         analysis_results = Map.put(analysis_results, :coverage, results) do

      # Generate overall score
      overall_score = calculate_overall_score(analysis_results)

      {:ok, %{
        analysis: analysis_results,
        overall_score: overall_score,
        recommendations: generate_recommendations(analysis_results)
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_credo_analysis(path, context) do
    # Execute credo in project directory
    case System.cmd("mix", ["credo", "--format", "json"],
                    cd: path,
                    stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, results} -> {:ok, parse_credo_results(results)}
          {:error, _} -> {:error, "Failed to parse Credo output"}
        end

      {output, exit_code} ->
        {:error, "Credo failed with exit code #{exit_code}: #{output}"}
    end
  end

  defp run_dialyzer_analysis(path, context) do
    case System.cmd("mix", ["dialyzer", "--format", "short"],
                    cd: path,
                    stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, %{issues: [], status: :clean}}

      {output, exit_code} ->
        issues = parse_dialyzer_output(output)
        {:ok, %{issues: issues, status: if(length(issues) > 0, do: :issues, else: :clean)}}
    end
  end

  defp run_test_coverage(path, context) do
    case System.cmd("mix", ["test", "--cover"],
                    cd: path,
                    env: [{"MIX_ENV", "test"}]) do
      {output, 0} ->
        coverage = extract_coverage_percentage(output)
        {:ok, %{coverage_percentage: coverage, status: coverage_status(coverage)}}

      {output, exit_code} ->
        {:error, "Test coverage failed: #{output}"}
    end
  end

  defp parse_credo_results(credo_json) do
    issues = get_in(credo_json, ["issues"]) || []

    %{
      total_issues: length(issues),
      by_priority: count_by_priority(issues),
      by_category: count_by_category(issues),
      files_with_issues: count_files_with_issues(issues)
    }
  end

  defp parse_dialyzer_output(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ".ex:"))
    |> Enum.map(&parse_dialyzer_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_dialyzer_line(line) do
    case Regex.run(~r/(.+\.ex):(\d+):(.+)/, line) do
      [_, file, line_num, message] ->
        %{file: file, line: String.to_integer(line_num), message: String.trim(message)}
      _ ->
        nil
    end
  end

  defp extract_coverage_percentage(output) do
    case Regex.run(~r/(\d+\.\d+)%/, output) do
      [_, percentage] -> String.to_float(percentage)
      _ -> 0.0
    end
  end

  defp calculate_overall_score(analysis) do
    credo_score = calculate_credo_score(analysis.credo)
    dialyzer_score = calculate_dialyzer_score(analysis.dialyzer)
    coverage_score = analysis.coverage.coverage_percentage

    # Weighted average
    (credo_score * 0.4 + dialyzer_score * 0.3 + coverage_score * 0.3) |> round()
  end

  defp calculate_credo_score(%{total_issues: 0}), do: 100
  defp calculate_credo_score(%{total_issues: issues}) do
    max(0, 100 - issues * 2)  # Subtract 2 points per issue
  end

  defp calculate_dialyzer_score(%{issues: []}), do: 100
  defp calculate_dialyzer_score(%{issues: issues}) do
    max(0, 100 - length(issues) * 5)  # Subtract 5 points per issue
  end

  defp generate_recommendations(analysis) do
    recommendations = []

    # Coverage recommendations
    recommendations = if analysis.coverage.coverage_percentage < 80 do
      ["Increase test coverage (currently #{analysis.coverage.coverage_percentage}%)" | recommendations]
    else
      recommendations
    end

    # Credo recommendations
    recommendations = if analysis.credo.total_issues > 10 do
      ["Address Credo issues (#{analysis.credo.total_issues} found)" | recommendations]
    else
      recommendations
    end

    # Dialyzer recommendations
    recommendations = if length(analysis.dialyzer.issues) > 0 do
      ["Fix Dialyzer type issues (#{length(analysis.dialyzer.issues)} found)" | recommendations]
    else
      recommendations
    end

    if recommendations == [] do
      ["Code quality looks good! Keep up the excellent work."]
    else
      recommendations
    end
  end
end
```

### Example 2: Deployment Tool

```elixir
defmodule MyApp.Tools.DeploymentManager do
  @behaviour Otto.Tool

  @impl Otto.Tool
  def name, do: "deploy"

  @impl Otto.Tool
  def permissions, do: [:read, :write, :exec, :network]

  @impl Otto.Tool
  def call(%{"environment" => env, "action" => action} = params, context) do
    case action do
      "deploy" ->
        deploy_application(env, params, context)
      "rollback" ->
        rollback_deployment(env, params, context)
      "status" ->
        check_deployment_status(env, context)
      "health_check" ->
        perform_health_check(env, context)
      _ ->
        {:error, "Unknown action: #{action}"}
    end
  end

  defp deploy_application(environment, params, context) do
    deployment_id = generate_deployment_id()

    steps = [
      {"validate_environment", &validate_environment/3},
      {"run_tests", &run_pre_deployment_tests/3},
      {"build_release", &build_release/3},
      {"backup_current", &backup_current_release/3},
      {"deploy_new", &deploy_new_release/3},
      {"health_check", &verify_deployment_health/3},
      {"update_load_balancer", &update_load_balancer/3},
      {"cleanup", &cleanup_old_releases/3}
    ]

    execute_deployment_steps(steps, environment, params, context, deployment_id)
  end

  defp execute_deployment_steps([], _env, _params, _context, deployment_id) do
    {:ok, %{
      deployment_id: deployment_id,
      status: :completed,
      message: "Deployment completed successfully"
    }}
  end

  defp execute_deployment_steps([{step_name, step_func} | rest], env, params, context, deployment_id) do
    update_deployment_status(deployment_id, step_name, :running)

    case step_func.(env, params, context) do
      {:ok, result} ->
        update_deployment_status(deployment_id, step_name, :completed, result)
        execute_deployment_steps(rest, env, params, context, deployment_id)

      {:error, reason} ->
        update_deployment_status(deployment_id, step_name, :failed, reason)

        # Attempt rollback on failure
        case params["auto_rollback"] do
          true ->
            rollback_on_failure(env, deployment_id, context)
          _ ->
            {:error, %{
              deployment_id: deployment_id,
              failed_step: step_name,
              reason: reason,
              message: "Deployment failed. Manual rollback may be required."
            }}
        end
    end
  end

  defp validate_environment(environment, _params, _context) do
    # Check if target environment is valid and accessible
    environments = ["staging", "production", "development"]

    if environment in environments do
      # Check environment connectivity
      case check_environment_connectivity(environment) do
        :ok -> {:ok, %{environment: environment, status: :ready}}
        {:error, reason} -> {:error, "Environment not accessible: #{reason}"}
      end
    else
      {:error, "Invalid environment: #{environment}. Must be one of #{inspect(environments)}"}
    end
  end

  defp run_pre_deployment_tests(_env, params, context) do
    test_suite = params["test_suite"] || "full"

    case System.cmd("mix", ["test", "--#{test_suite}"],
                    cd: context.working_dir,
                    env: [{"MIX_ENV", "test"}]) do
      {output, 0} ->
        {:ok, %{tests: :passed, output: output}}

      {output, exit_code} ->
        {:error, "Tests failed with exit code #{exit_code}: #{output}"}
    end
  end

  defp build_release(environment, params, context) do
    mix_env = environment_to_mix_env(environment)

    case System.cmd("mix", ["release", "--env", mix_env],
                    cd: context.working_dir,
                    env: [{"MIX_ENV", mix_env}]) do
      {output, 0} ->
        release_path = extract_release_path(output)
        {:ok, %{release_built: true, release_path: release_path}}

      {output, exit_code} ->
        {:error, "Release build failed: #{output}"}
    end
  end

  defp backup_current_release(environment, _params, _context) do
    backup_id = "backup_#{DateTime.utc_now() |> DateTime.to_iso8601()}"

    # Implementation depends on deployment infrastructure
    case create_deployment_backup(environment, backup_id) do
      :ok -> {:ok, %{backup_id: backup_id, backup_created: true}}
      {:error, reason} -> {:error, "Backup failed: #{reason}"}
    end
  end

  defp deploy_new_release(environment, params, context) do
    # Implementation depends on deployment method (Docker, systemd, etc.)
    case get_deployment_method(environment) do
      :docker -> deploy_docker_release(environment, params, context)
      :systemd -> deploy_systemd_release(environment, params, context)
      :kubernetes -> deploy_k8s_release(environment, params, context)
      method -> {:error, "Unsupported deployment method: #{method}"}
    end
  end

  defp deploy_docker_release(environment, params, context) do
    image_tag = params["image_tag"] || "latest"

    commands = [
      ["docker", "pull", "myapp:#{image_tag}"],
      ["docker", "stop", "myapp_#{environment}"],
      ["docker", "rm", "myapp_#{environment}"],
      ["docker", "run", "-d", "--name", "myapp_#{environment}",
       "--env-file", ".env.#{environment}", "myapp:#{image_tag}"]
    ]

    execute_commands(commands)
  end

  defp verify_deployment_health(environment, _params, _context) do
    health_url = get_health_check_url(environment)
    max_attempts = 30  # 30 attempts with 10 second intervals = 5 minutes

    check_health_with_retry(health_url, max_attempts)
  end

  defp check_health_with_retry(_url, 0) do
    {:error, "Health check failed after maximum attempts"}
  end

  defp check_health_with_retry(url, attempts_remaining) do
    case HTTPoison.get(url, [], timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"status" => "ok"}} ->
            {:ok, %{health_status: :healthy, attempts_used: 30 - attempts_remaining + 1}}
          _ ->
            retry_health_check(url, attempts_remaining)
        end

      _ ->
        retry_health_check(url, attempts_remaining)
    end
  end

  defp retry_health_check(url, attempts_remaining) do
    Process.sleep(10_000)  # Wait 10 seconds
    check_health_with_retry(url, attempts_remaining - 1)
  end

  defp update_deployment_status(deployment_id, step, status, details \\ %{}) do
    status_data = %{
      deployment_id: deployment_id,
      step: step,
      status: status,
      details: details,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(:deployments, {deployment_id, status_data})

    # Emit telemetry
    :telemetry.execute(
      [:deployment, :step, status],
      %{deployment_id: deployment_id},
      %{step: step, details: details}
    )
  end

  # Additional helper functions...
  defp generate_deployment_id do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "deploy_#{timestamp}_#{random}"
  end
end
```

## Publishing Tools

### 1. Package Structure

```
my_otto_tools/
├── lib/
│   └── my_otto_tools/
│       ├── application.ex
│       ├── registry.ex
│       └── tools/
│           ├── database.ex
│           ├── slack.ex
│           └── monitoring.ex
├── test/
│   └── tools/
│       ├── database_test.exs
│       ├── slack_test.exs
│       └── monitoring_test.exs
├── mix.exs
├── README.md
└── CHANGELOG.md
```

### 2. Package Configuration

```elixir
# mix.exs
defmodule MyOttoTools.MixProject do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      app: :my_otto_tools,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MyOttoTools.Application, []}
    ]
  end

  defp deps do
    [
      {:otto, "~> 0.1.0"},
      {:jason, "~> 1.4"},
      {:httpoison, "~> 2.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "my_otto_tools",
      maintainers: ["Your Name"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/yourorg/my_otto_tools"},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp description do
    """
    A collection of custom Otto tools for database operations,
    Slack integration, and system monitoring.
    """
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: "https://github.com/yourorg/my_otto_tools"
    ]
  end
end
```

### 3. Auto-Registration Module

```elixir
defmodule MyOttoTools.Registry do
  @moduledoc """
  Registry for auto-discovering and registering MyOttoTools.
  """

  @tools [
    MyOttoTools.Tools.Database,
    MyOttoTools.Tools.Slack,
    MyOttoTools.Tools.Monitoring
  ]

  @doc """
  Register all tools in this package with Otto.

  Call this function in your application startup:

      MyOttoTools.Registry.register_all()
  """
  def register_all do
    Enum.each(@tools, &Otto.ToolBus.register_tool/1)
  end

  @doc """
  Get list of all tools provided by this package.
  """
  def list_tools do
    Enum.map(@tools, & &1.name())
  end

  @doc """
  Get information about all tools in this package.
  """
  def tool_info do
    Enum.map(@tools, fn tool ->
      %{
        name: tool.name(),
        module: tool,
        permissions: tool.permissions(),
        schema: if(function_exported?(tool, :param_schema, 0), do: tool.param_schema(), else: nil)
      }
    end)
  end
end
```

### 4. Documentation

Create comprehensive README.md:

```markdown
# MyOttoTools

A collection of high-quality Otto tools for database operations, Slack integration, and system monitoring.

## Installation

Add to your mix.exs dependencies:

```elixir
def deps do
  [
    {:my_otto_tools, "~> 1.0"}
  ]
end
```

Register tools in your application:

```elixir
# In your Application.start/2
MyOttoTools.Registry.register_all()
```

## Available Tools

### database
- **Permissions**: `[:read, :write]`
- **Purpose**: Execute SQL queries with safety checks
- **Example**:
  ```yaml
  tools: ["database"]
  tool_config:
    database:
      connection_url: "${DATABASE_URL}"
      query_timeout: 30000
  ```

### slack
- **Permissions**: `[:network]`
- **Purpose**: Send messages and upload files to Slack
- **Example**:
  ```yaml
  tools: ["slack"]
  tool_config:
    slack:
      webhook_url: "${SLACK_WEBHOOK_URL}"
      default_channel: "#alerts"
  ```

### monitoring
- **Permissions**: `[:read, :network]`
- **Purpose**: System health checks and metrics collection
- **Example**:
  ```yaml
  tools: ["monitoring"]
  tool_config:
    monitoring:
      metrics_endpoint: "http://localhost:9090/metrics"
      alert_threshold: 90
  ```

## Configuration

Each tool can be configured through the `tool_config` section of your agent configuration:

```yaml
tool_config:
  database:
    connection_url: "${DATABASE_URL}"
    max_query_time: 30000
    read_only_mode: false

  slack:
    webhook_url: "${SLACK_WEBHOOK_URL}"
    bot_token: "${SLACK_BOT_TOKEN}"
    default_channel: "#general"

  monitoring:
    prometheus_url: "${PROMETHEUS_URL}"
    grafana_url: "${GRAFANA_URL}"
    alert_manager_url: "${ALERT_MANAGER_URL}"
```

## Examples

See the [examples/](examples/) directory for complete agent configurations using these tools.

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-tool`)
3. Add tests for your tool
4. Ensure all tests pass (`mix test`)
5. Update documentation
6. Commit your changes (`git commit -am 'Add amazing tool'`)
7. Push to the branch (`git push origin feature/amazing-tool`)
8. Create a Pull Request

## License

Licensed under the Apache License, Version 2.0.
```

---

This comprehensive tool development guide provides everything needed to create production-ready Otto tools with proper security, testing, and documentation. Start with simple tools and gradually implement more advanced patterns as your needs grow.