# Otto AgentServer API Reference

This document provides comprehensive documentation for the Otto AgentServer, including lifecycle management, state transitions, invocation patterns, and monitoring capabilities.

## Table of Contents

1. [AgentServer Overview](#agentserver-overview)
2. [Agent Lifecycle](#agent-lifecycle)
3. [State Management](#state-management)
4. [Invocation API](#invocation-api)
5. [Budget Enforcement](#budget-enforcement)
6. [Context Management](#context-management)
7. [Checkpointing](#checkpointing)
8. [Error Handling](#error-handling)
9. [Monitoring & Observability](#monitoring--observability)
10. [API Reference](#api-reference)

## AgentServer Overview

The `Otto.Agent.Server` is a GenServer that manages the complete lifecycle of an AI agent, from initialization through execution to cleanup. It handles LLM communication, tool invocation, budget tracking, and state persistence.

### Core Responsibilities

- **Lifecycle Management**: Agent startup, execution, and shutdown
- **State Persistence**: Maintain conversation history and context
- **Budget Enforcement**: Track and enforce time/token/cost limits
- **Tool Coordination**: Manage tool invocations during LLM streaming
- **Error Recovery**: Handle failures and implement retry logic
- **Checkpointing**: Persist execution artifacts and state
- **Telemetry**: Emit events for monitoring and debugging

### Architecture

```
AgentServer (GenServer)
├── State Management
│   ├── Configuration (Otto.Agent.Config)
│   ├── Context (Otto.Agent.Context)
│   ├── Transcript (circular buffer)
│   └── Execution State
├── Budget Management
│   ├── Time Budget (countdown timer)
│   ├── Token Budget (running counter)
│   └── Cost Budget (dollar tracking)
├── Tool Integration
│   ├── ToolBus communication
│   ├── Streaming tool calls
│   └── Result aggregation
├── LLM Communication
│   ├── Provider client (Anthropic)
│   ├── Streaming handler
│   └── Response parsing
└── Persistence
    ├── Checkpointer integration
    ├── Artifact storage
    └── State snapshots
```

## Agent Lifecycle

An agent goes through several distinct phases during its lifetime:

### Lifecycle States

```elixir
defmodule Otto.Agent.State do
  @type status ::
    :initializing |
    :ready |
    :executing |
    :waiting_for_tools |
    :streaming |
    :completed |
    :failed |
    :budget_exceeded |
    :terminated

  defstruct [
    status: :initializing,
    config: nil,
    context: nil,
    transcript: [],
    budgets: %{},
    execution: %{},
    metadata: %{}
  ]
end
```

### Lifecycle Flow

```
┌─────────────┐
│ INITIALIZED │ ──startup──► ┌───────┐
└─────────────┘               │ READY │
                               └───┬───┘
                                   │ invoke/1
                                   ▼
                           ┌────────────┐
                           │ EXECUTING  │
                           └─────┬──────┘
                                 │
                        ┌────────▼────────┐
                        │ STREAMING       │ ◄──► ┌──────────────────┐
                        └────────┬────────┘      │ WAITING_FOR_TOOLS│
                                 │               └──────────────────┘
                                 ▼
                        ┌─────────────────┐
                    ┌──►│    COMPLETED    │
                    │   └─────────────────┘
                    │
          ┌─────────┴─────────┐         ┌─────────────────┐
          │      FAILED       │         │ BUDGET_EXCEEDED │
          └───────────────────┘         └─────────────────┘
                    │                           │
                    └───────────┬───────────────┘
                                ▼
                        ┌───────────────┐
                        │  TERMINATED   │
                        └───────────────┘
```

### State Transitions

#### 1. Initialization → Ready

```elixir
def init(%Otto.Agent.Config{} = config) do
  state = %Otto.Agent.State{
    status: :initializing,
    config: config,
    context: Otto.Agent.Context.new(config),
    transcript: CircularBuffer.new(config.transcript_limit),
    budgets: initialize_budgets(config),
    execution: %{
      started_at: nil,
      correlation_id: nil,
      task_spec: nil
    },
    metadata: %{
      created_at: DateTime.utc_now(),
      invocation_count: 0
    }
  }

  # Validate configuration and initialize resources
  with :ok <- validate_config(config),
       :ok <- initialize_tools(config.tools),
       :ok <- setup_budget_guards(state.budgets) do

    # Transition to ready
    new_state = %{state | status: :ready}

    :telemetry.execute(
      [:otto, :agent, :ready],
      %{startup_time_ms: measure_startup_time()},
      %{agent_id: config.name}
    )

    {:ok, new_state}
  else
    {:error, reason} ->
      {:stop, {:initialization_failed, reason}, state}
  end
end
```

#### 2. Ready → Executing

```elixir
def handle_call({:invoke, task_spec}, _from, %{status: :ready} = state) do
  # Pre-execution validation
  with :ok <- validate_task_spec(task_spec),
       :ok <- check_budget_availability(state.budgets),
       :ok <- validate_tool_permissions(task_spec, state.config) do

    execution = %{
      started_at: DateTime.utc_now(),
      correlation_id: generate_correlation_id(),
      task_spec: task_spec,
      budget_guard: start_budget_guard(state.budgets)
    }

    new_state = %{state |
      status: :executing,
      execution: execution
    }

    # Start execution asynchronously
    GenServer.cast(self(), :begin_execution)

    {:reply, {:ok, execution.correlation_id}, new_state}
  else
    {:error, reason} ->
      {:reply, {:error, reason}, state}
  end
end
```

#### 3. Executing → Streaming

```elixir
def handle_cast(:begin_execution, %{status: :executing} = state) do
  # Build LLM request from task spec and context
  request = build_llm_request(state.execution.task_spec, state.context, state.config)

  # Start streaming request
  {:ok, stream_pid} = Otto.LLM.Client.stream_request(
    request,
    callback: &handle_stream_chunk/2,
    context: %{agent_pid: self()}
  )

  execution = %{state.execution | stream_pid: stream_pid}
  new_state = %{state | status: :streaming, execution: execution}

  :telemetry.execute(
    [:otto, :agent, :execution_started],
    %{tokens: request.estimated_tokens},
    %{agent_id: state.config.name, correlation_id: execution.correlation_id}
  )

  {:noreply, new_state}
end
```

#### 4. Streaming ↔ Waiting for Tools

```elixir
# Handle tool call during streaming
def handle_info({:stream_chunk, %{type: :tool_call} = chunk}, %{status: :streaming} = state) do
  # Transition to waiting for tools
  new_state = %{state | status: :waiting_for_tools}

  # Execute tool asynchronously
  Task.start(fn ->
    result = Otto.ToolBus.call_tool(
      chunk.tool_name,
      chunk.parameters,
      build_tool_context(state)
    )

    GenServer.cast(self(), {:tool_result, chunk.call_id, result})
  end)

  {:noreply, new_state}
end

# Handle tool result
def handle_cast({:tool_result, call_id, result}, %{status: :waiting_for_tools} = state) do
  # Send tool result to LLM stream
  Otto.LLM.Client.send_tool_result(state.execution.stream_pid, call_id, result)

  # Update transcript with tool invocation
  transcript_entry = %{
    type: :tool_result,
    tool_call_id: call_id,
    result: result,
    timestamp: DateTime.utc_now()
  }

  new_transcript = CircularBuffer.insert(state.transcript, transcript_entry)
  new_state = %{state | transcript: new_transcript, status: :streaming}

  {:noreply, new_state}
end
```

#### 5. Streaming → Completed

```elixir
# Handle stream completion
def handle_info({:stream_complete, response}, %{status: :streaming} = state) do
  # Calculate final metrics
  execution_time = DateTime.diff(DateTime.utc_now(), state.execution.started_at, :millisecond)

  result = %{
    content: response.content,
    usage: response.usage,
    execution_time_ms: execution_time,
    correlation_id: state.execution.correlation_id
  }

  # Update budgets
  new_budgets = update_budgets(state.budgets, response.usage, execution_time)

  # Create checkpoint
  {:ok, checkpoint_ref} = Otto.Checkpointer.store_result(
    state.execution.correlation_id,
    result,
    state.transcript
  )

  new_state = %{state |
    status: :completed,
    budgets: new_budgets,
    execution: Map.put(state.execution, :result, result),
    metadata: Map.update(state.metadata, :invocation_count, 1, &(&1 + 1))
  }

  :telemetry.execute(
    [:otto, :agent, :completed],
    %{
      execution_time_ms: execution_time,
      tokens_used: response.usage.total_tokens,
      cost_cents: calculate_cost(response.usage, state.config.model)
    },
    %{agent_id: state.config.name, correlation_id: state.execution.correlation_id}
  )

  {:noreply, new_state}
end
```

## State Management

The AgentServer maintains several types of state:

### Configuration State

```elixir
defmodule Otto.Agent.State do
  defstruct [
    # Configuration (immutable after init)
    config: %Otto.Agent.Config{},

    # Runtime state
    status: :initializing,
    context: %Otto.Agent.Context{},
    transcript: %CircularBuffer{},

    # Budget tracking
    budgets: %{
      time: %{limit: 300, used: 0, remaining: 300},
      tokens: %{limit: 10000, used: 0, remaining: 10000},
      cost: %{limit: 100, used: 0, remaining: 100}
    },

    # Current execution
    execution: %{
      started_at: nil,
      correlation_id: nil,
      task_spec: nil,
      stream_pid: nil,
      result: nil
    },

    # Metadata and metrics
    metadata: %{
      created_at: DateTime.t(),
      invocation_count: 0,
      last_active_at: DateTime.t(),
      errors: []
    }
  ]
end
```

### Context State

```elixir
defmodule Otto.Agent.Context do
  @type t :: %__MODULE__{
    agent_id: String.t(),
    session_id: String.t(),
    working_dir: String.t(),
    permissions: [atom()],
    tool_context: Otto.ToolContext.t(),
    system_prompt: String.t(),
    conversation_metadata: map()
  }

  def new(%Otto.Agent.Config{} = config) do
    %__MODULE__{
      agent_id: config.name,
      session_id: generate_session_id(),
      working_dir: resolve_working_dir(config.working_dir),
      permissions: derive_permissions(config.tools),
      tool_context: build_tool_context(config),
      system_prompt: config.system_prompt,
      conversation_metadata: %{
        started_at: DateTime.utc_now(),
        model: config.model,
        provider: config.provider
      }
    }
  end

  def update_metadata(context, key, value) do
    %{context | conversation_metadata: Map.put(context.conversation_metadata, key, value)}
  end
end
```

### Budget State

```elixir
defmodule Otto.Agent.BudgetState do
  @type budget_type :: :time | :tokens | :cost

  @type budget :: %{
    limit: pos_integer(),
    used: non_neg_integer(),
    remaining: non_neg_integer(),
    warnings_sent: [String.t()],
    exceeded: boolean()
  }

  def initialize(config) do
    %{
      time: %{
        limit: config.budgets.time_seconds,
        used: 0,
        remaining: config.budgets.time_seconds,
        warnings_sent: [],
        exceeded: false
      },
      tokens: %{
        limit: config.budgets.tokens,
        used: 0,
        remaining: config.budgets.tokens,
        warnings_sent: [],
        exceeded: false
      },
      cost: %{
        limit: config.budgets.cost_cents,
        used: 0,
        remaining: config.budgets.cost_cents,
        warnings_sent: [],
        exceeded: false
      }
    }
  end

  def consume(budgets, type, amount) do
    budget = Map.get(budgets, type)

    new_budget = %{budget |
      used: budget.used + amount,
      remaining: max(0, budget.remaining - amount)
    }

    # Check for warnings (80% threshold)
    new_budget = maybe_add_warning(new_budget, amount)

    # Check for exceeded
    new_budget = %{new_budget | exceeded: new_budget.remaining == 0}

    Map.put(budgets, type, new_budget)
  end

  defp maybe_add_warning(budget, amount) do
    threshold = budget.limit * 0.8

    if budget.used >= threshold and "80_percent" not in budget.warnings_sent do
      %{budget | warnings_sent: ["80_percent" | budget.warnings_sent]}
    else
      budget
    end
  end
end
```

## Invocation API

The AgentServer provides both synchronous and asynchronous invocation patterns:

### Synchronous Invocation

```elixir
@spec invoke(pid(), String.t() | Otto.TaskSpec.t(), keyword()) ::
  {:ok, Otto.Agent.Result.t()} | {:error, any()}

def invoke(agent_pid, task, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 120_000)

  case GenServer.call(agent_pid, {:invoke, task}, timeout) do
    {:ok, correlation_id} ->
      # Wait for completion
      wait_for_result(agent_pid, correlation_id, timeout)

    {:error, reason} ->
      {:error, reason}
  end
end

# Wait for execution to complete
defp wait_for_result(agent_pid, correlation_id, timeout) do
  receive do
    {:agent_result, ^correlation_id, result} -> {:ok, result}
    {:agent_error, ^correlation_id, error} -> {:error, error}
  after
    timeout -> {:error, :timeout}
  end
end
```

### Asynchronous Invocation

```elixir
@spec invoke_async(pid(), String.t() | Otto.TaskSpec.t(), keyword()) ::
  {:ok, reference()} | {:error, any()}

def invoke_async(agent_pid, task, opts \\ []) do
  callback = Keyword.get(opts, :callback)
  correlation_id = generate_correlation_id()

  case GenServer.cast(agent_pid, {:invoke_async, task, correlation_id, self(), callback}) do
    :ok -> {:ok, correlation_id}
    error -> error
  end
end

# Handle async invocation
def handle_cast({:invoke_async, task, correlation_id, caller_pid, callback}, state) do
  # Similar to synchronous but send result to caller
  case start_execution(task, correlation_id, state) do
    {:ok, new_state} ->
      # Execution started, will send result later
      {:noreply, new_state}

    {:error, reason} ->
      send(caller_pid, {:agent_error, correlation_id, reason})
      {:noreply, state}
  end
end
```

### Streaming Invocation

```elixir
@spec invoke_stream(pid(), String.t() | Otto.TaskSpec.t(), (any() -> any())) ::
  {:ok, reference()} | {:error, any()}

def invoke_stream(agent_pid, task, stream_callback) do
  GenServer.call(agent_pid, {:invoke_stream, task, stream_callback})
end

# Handle streaming chunks
def handle_info({:stream_chunk, chunk}, state) do
  # Forward to registered callback
  if state.execution.stream_callback do
    state.execution.stream_callback.(chunk)
  end

  {:noreply, state}
end
```

### Task Specifications

```elixir
defmodule Otto.TaskSpec do
  @type t :: %__MODULE__{
    instruction: String.t(),
    context: map(),
    tools_allowed: [String.t()] | :all,
    max_iterations: pos_integer(),
    timeout_ms: pos_integer() | nil,
    metadata: map()
  }

  defstruct [
    instruction: nil,
    context: %{},
    tools_allowed: :all,
    max_iterations: 10,
    timeout_ms: nil,
    metadata: %{}
  ]

  # Create from string
  def from_string(instruction) when is_binary(instruction) do
    %__MODULE__{instruction: instruction}
  end

  # Create with options
  def new(instruction, opts \\ []) do
    %__MODULE__{
      instruction: instruction,
      context: Keyword.get(opts, :context, %{}),
      tools_allowed: Keyword.get(opts, :tools_allowed, :all),
      max_iterations: Keyword.get(opts, :max_iterations, 10),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
```

## Budget Enforcement

Otto enforces budgets at multiple levels with different strategies:

### Budget Types and Enforcement

#### Time Budgets

```elixir
defmodule Otto.Agent.TimeBudget do
  def start_guard(time_limit_seconds) do
    parent = self()

    spawn_link(fn ->
      Process.sleep(time_limit_seconds * 1000)
      send(parent, {:budget_exceeded, :time, time_limit_seconds})
    end)
  end

  def handle_info({:budget_exceeded, :time, limit}, state) do
    # Gracefully terminate execution
    case state.status do
      :streaming ->
        Otto.LLM.Client.cancel_stream(state.execution.stream_pid)

      :waiting_for_tools ->
        # Let current tools finish but prevent new ones
        :ok

      _ ->
        :ok
    end

    new_state = %{state | status: :budget_exceeded}

    :telemetry.execute(
      [:otto, :budget, :exceeded],
      %{type: :time, limit: limit},
      %{agent_id: state.config.name}
    )

    {:noreply, new_state}
  end
end
```

#### Token Budgets

```elixir
defmodule Otto.Agent.TokenBudget do
  def check_pre_request(budgets, estimated_tokens) do
    remaining = budgets.tokens.remaining

    if estimated_tokens > remaining do
      {:error, {:budget_exceeded, :tokens, %{
        requested: estimated_tokens,
        remaining: remaining
      }}}
    else
      :ok
    end
  end

  def update_usage(budgets, %{input_tokens: input, output_tokens: output}) do
    total_tokens = input + output

    new_budgets = Otto.Agent.BudgetState.consume(budgets, :tokens, total_tokens)

    if new_budgets.tokens.exceeded do
      :telemetry.execute(
        [:otto, :budget, :exceeded],
        %{type: :tokens, used: new_budgets.tokens.used},
        %{agent_id: "current_agent"}  # From context
      )
    end

    new_budgets
  end
end
```

#### Cost Budgets

```elixir
defmodule Otto.Agent.CostBudget do
  # Model pricing (cents per 1K tokens)
  @pricing %{
    "claude-3-opus-20240229" => %{input: 1.5, output: 7.5},
    "claude-3-sonnet-20240229" => %{input: 0.3, output: 1.5},
    "claude-3-haiku-20240307" => %{input: 0.025, output: 0.125},
    "claude-3-5-sonnet-20240620" => %{input: 0.3, output: 1.5}
  }

  def calculate_cost(usage, model) do
    pricing = Map.get(@pricing, model)

    if pricing do
      input_cost = (usage.input_tokens / 1000) * pricing.input
      output_cost = (usage.output_tokens / 1000) * pricing.output
      round((input_cost + output_cost) * 100)  # Convert to cents
    else
      0  # Unknown model
    end
  end

  def check_estimated_cost(budgets, estimated_tokens, model) do
    estimated_cost = calculate_cost(
      %{input_tokens: estimated_tokens, output_tokens: estimated_tokens},
      model
    )

    if estimated_cost > budgets.cost.remaining do
      {:error, {:budget_exceeded, :cost, %{
        estimated: estimated_cost,
        remaining: budgets.cost.remaining
      }}}
    else
      :ok
    end
  end
end
```

### Budget Warnings

Otto sends warnings when budgets reach 80% utilization:

```elixir
def maybe_send_warning(budgets, type) do
  budget = Map.get(budgets, type)
  utilization = budget.used / budget.limit

  cond do
    utilization >= 0.8 and "80_percent" not in budget.warnings_sent ->
      send_warning(type, :eighty_percent, budget)

    utilization >= 0.9 and "90_percent" not in budget.warnings_sent ->
      send_warning(type, :ninety_percent, budget)

    true ->
      :ok
  end
end

defp send_warning(type, level, budget) do
  :telemetry.execute(
    [:otto, :budget, :warning],
    %{
      type: type,
      level: level,
      used: budget.used,
      remaining: budget.remaining,
      utilization: budget.used / budget.limit
    },
    %{agent_id: "current_agent"}
  )
end
```

## Context Management

The AgentServer maintains rich context throughout execution:

### Tool Context

```elixir
defmodule Otto.ToolContext do
  def build_from_agent_state(state) do
    %__MODULE__{
      agent_id: state.config.name,
      agent_config: state.config,
      working_dir: state.context.working_dir,
      permissions: state.context.permissions,
      sandbox: build_sandbox_config(state.config),
      budget_guard: state.execution.budget_guard,
      correlation_id: state.execution.correlation_id,
      metadata: %{
        invocation_count: state.metadata.invocation_count,
        session_id: state.context.session_id,
        started_at: state.execution.started_at
      }
    }
  end

  defp build_sandbox_config(config) do
    if config.sandbox do
      %{
        enabled: config.sandbox.enabled,
        allowed_paths: resolve_paths(config.sandbox.allowed_paths, config.working_dir),
        denied_patterns: config.sandbox.denied_patterns,
        max_file_size: config.sandbox.max_file_size
      }
    else
      nil
    end
  end
end
```

### Conversation Context

```elixir
defmodule Otto.Agent.ConversationContext do
  def build_messages(transcript, system_prompt) do
    messages = [
      %{role: "system", content: system_prompt}
    ]

    # Add conversation history from transcript
    conversation_messages =
      transcript
      |> CircularBuffer.to_list()
      |> Enum.map(&transcript_entry_to_message/1)
      |> Enum.reject(&is_nil/1)

    messages ++ conversation_messages
  end

  defp transcript_entry_to_message(%{type: :user_message, content: content}) do
    %{role: "user", content: content}
  end

  defp transcript_entry_to_message(%{type: :assistant_message, content: content}) do
    %{role: "assistant", content: content}
  end

  defp transcript_entry_to_message(%{type: :tool_call, name: name, parameters: params}) do
    %{
      role: "assistant",
      content: nil,
      tool_calls: [%{
        type: "function",
        function: %{name: name, arguments: Jason.encode!(params)}
      }]
    }
  end

  defp transcript_entry_to_message(%{type: :tool_result, result: result, tool_call_id: id}) do
    %{
      role: "tool",
      tool_call_id: id,
      content: format_tool_result(result)
    }
  end

  defp transcript_entry_to_message(_), do: nil
end
```

## Checkpointing

Otto automatically creates checkpoints at key execution points:

### Checkpoint Types

```elixir
defmodule Otto.Agent.Checkpoint do
  @type checkpoint_type :: :start | :tool_call | :result | :error | :budget_exceeded

  def create(type, state, additional_data \\ %{}) do
    checkpoint = %{
      type: type,
      timestamp: DateTime.utc_now(),
      correlation_id: state.execution.correlation_id,
      agent_id: state.config.name,
      status: state.status,

      # State snapshot
      transcript: CircularBuffer.to_list(state.transcript),
      budgets: state.budgets,

      # Execution data
      execution_metadata: Map.take(state.execution, [:started_at, :task_spec]),

      # Additional type-specific data
      data: additional_data
    }

    Otto.Checkpointer.store_checkpoint(checkpoint)
  end
end

# Usage in different scenarios
def handle_info({:stream_chunk, %{type: :tool_call} = chunk}, state) do
  # Checkpoint before tool execution
  Otto.Agent.Checkpoint.create(:tool_call, state, %{
    tool_name: chunk.tool_name,
    parameters: chunk.parameters,
    call_id: chunk.call_id
  })

  # Continue with tool execution...
end
```

### Artifact Storage

```elixir
defmodule Otto.Agent.Artifacts do
  def store_execution_result(correlation_id, result, transcript) do
    artifacts = [
      create_result_artifact(result),
      create_transcript_artifact(transcript),
      create_metrics_artifact(result)
    ]

    Otto.Checkpointer.store_artifacts(correlation_id, artifacts)
  end

  defp create_result_artifact(result) do
    %Otto.Artifact{
      type: :result,
      content_type: "application/json",
      content: Jason.encode!(result),
      size: byte_size(Jason.encode!(result)),
      checksum: :crypto.hash(:sha256, Jason.encode!(result)) |> Base.encode16()
    }
  end

  defp create_transcript_artifact(transcript) do
    content =
      transcript
      |> CircularBuffer.to_list()
      |> Jason.encode!(pretty: true)

    %Otto.Artifact{
      type: :transcript,
      content_type: "application/json",
      content: content,
      size: byte_size(content),
      checksum: :crypto.hash(:sha256, content) |> Base.encode16()
    }
  end

  defp create_metrics_artifact(result) do
    metrics = %{
      execution_time_ms: result.execution_time_ms,
      tokens_used: result.usage.total_tokens,
      cost_cents: result.cost_cents,
      tool_calls: length(result.tool_calls || [])
    }

    content = Jason.encode!(metrics)

    %Otto.Artifact{
      type: :metrics,
      content_type: "application/json",
      content: content,
      size: byte_size(content),
      checksum: :crypto.hash(:sha256, content) |> Base.encode16()
    }
  end
end
```

## Error Handling

The AgentServer implements comprehensive error handling and recovery:

### Error Types

```elixir
defmodule Otto.Agent.Error do
  defexception [:type, :message, :details, :recoverable]

  @type error_type ::
    :configuration_error |
    :budget_exceeded |
    :tool_error |
    :llm_error |
    :timeout |
    :validation_error |
    :resource_error

  def new(type, message, details \\ %{}) do
    %__MODULE__{
      type: type,
      message: message,
      details: details,
      recoverable: recoverable?(type)
    }
  end

  defp recoverable?(:tool_error), do: true
  defp recoverable?(:llm_error), do: true
  defp recoverable?(:timeout), do: true
  defp recoverable?(_), do: false
end
```

### Retry Logic

```elixir
def handle_llm_error(error, state, attempt \\ 1) do
  max_attempts = state.config.retry_attempts

  if attempt <= max_attempts and recoverable_error?(error) do
    # Exponential backoff
    delay = min(1000 * :math.pow(2, attempt - 1), 30_000)
    Process.send_after(self(), {:retry_execution, attempt + 1}, round(delay))

    :telemetry.execute(
      [:otto, :agent, :retry],
      %{attempt: attempt, delay_ms: delay},
      %{agent_id: state.config.name, error_type: error.type}
    )

    {:noreply, state}
  else
    # Max retries exceeded or non-recoverable error
    final_error = %Otto.Agent.Error{
      type: :max_retries_exceeded,
      message: "Failed after #{max_attempts} attempts",
      details: %{original_error: error, attempts: attempt}
    }

    new_state = %{state | status: :failed, execution: Map.put(state.execution, :error, final_error)}

    :telemetry.execute(
      [:otto, :agent, :failed],
      %{attempts: attempt},
      %{agent_id: state.config.name, error_type: error.type}
    )

    {:noreply, new_state}
  end
end

defp recoverable_error?(%{type: type}) do
  type in [:llm_error, :timeout, :tool_error]
end
```

### Error Recovery Strategies

```elixir
defmodule Otto.Agent.ErrorRecovery do
  def handle_tool_error(tool_name, error, state) do
    recovery_strategy = get_recovery_strategy(tool_name, error)

    case recovery_strategy do
      :retry_with_backoff ->
        schedule_tool_retry(tool_name, error, state)

      :use_fallback_tool ->
        try_fallback_tool(tool_name, error, state)

      :skip_and_continue ->
        continue_without_tool(tool_name, error, state)

      :abort ->
        abort_execution(tool_name, error, state)
    end
  end

  defp get_recovery_strategy(tool_name, error) do
    case {tool_name, error.type} do
      {"fs.read", :file_not_found} -> :skip_and_continue
      {"http.get", :timeout} -> :retry_with_backoff
      {"http.get", :rate_limited} -> :retry_with_backoff
      {"test.run", :timeout} -> :abort
      {_, :permission_denied} -> :abort
      _ -> :retry_with_backoff
    end
  end
end
```

## Monitoring & Observability

Otto provides comprehensive monitoring through telemetry events and metrics:

### Telemetry Events

```elixir
# Agent lifecycle events
:telemetry.execute([:otto, :agent, :started], measurements, metadata)
:telemetry.execute([:otto, :agent, :ready], measurements, metadata)
:telemetry.execute([:otto, :agent, :invoked], measurements, metadata)
:telemetry.execute([:otto, :agent, :completed], measurements, metadata)
:telemetry.execute([:otto, :agent, :failed], measurements, metadata)
:telemetry.execute([:otto, :agent, :terminated], measurements, metadata)

# Execution events
:telemetry.execute([:otto, :agent, :execution, :started], measurements, metadata)
:telemetry.execute([:otto, :agent, :execution, :streaming], measurements, metadata)
:telemetry.execute([:otto, :agent, :execution, :tool_call], measurements, metadata)
:telemetry.execute([:otto, :agent, :execution, :completed], measurements, metadata)

# Budget events
:telemetry.execute([:otto, :budget, :warning], measurements, metadata)
:telemetry.execute([:otto, :budget, :exceeded], measurements, metadata)

# Error events
:telemetry.execute([:otto, :agent, :error], measurements, metadata)
:telemetry.execute([:otto, :agent, :retry], measurements, metadata)
```

### Custom Metrics

```elixir
defmodule Otto.Agent.Metrics do
  def setup_metrics() do
    :telemetry.attach_many(
      "otto-agent-metrics",
      [
        [:otto, :agent, :completed],
        [:otto, :agent, :failed],
        [:otto, :budget, :exceeded]
      ],
      &handle_metric_event/4,
      %{}
    )
  end

  def handle_metric_event([:otto, :agent, :completed], measurements, metadata, _config) do
    # Update completion metrics
    :prometheus_counter.inc(agent_completions_total, [metadata.agent_id])
    :prometheus_histogram.observe(agent_execution_duration_seconds,
      [metadata.agent_id], measurements.execution_time_ms / 1000)
    :prometheus_histogram.observe(agent_token_usage,
      [metadata.agent_id], measurements.tokens_used)
  end

  def handle_metric_event([:otto, :agent, :failed], measurements, metadata, _config) do
    :prometheus_counter.inc(agent_failures_total,
      [metadata.agent_id, metadata.error_type])
  end

  def handle_metric_event([:otto, :budget, :exceeded], measurements, metadata, _config) do
    :prometheus_counter.inc(budget_exceeded_total,
      [metadata.agent_id, measurements.type])
  end
end
```

### Health Checks

```elixir
defmodule Otto.Agent.HealthCheck do
  def check_agent_health(agent_pid) do
    try do
      case GenServer.call(agent_pid, :health_check, 5000) do
        {:ok, status} -> {:healthy, status}
        {:error, reason} -> {:unhealthy, reason}
      end
    catch
      :exit, {:timeout, _} -> {:unhealthy, :timeout}
      :exit, {:noproc, _} -> {:unhealthy, :not_running}
    end
  end

  def handle_call(:health_check, _from, state) do
    health_status = %{
      status: state.status,
      uptime_ms: DateTime.diff(DateTime.utc_now(), state.metadata.created_at, :millisecond),
      invocation_count: state.metadata.invocation_count,
      last_active: state.metadata.last_active_at,
      budget_utilization: %{
        time: state.budgets.time.used / state.budgets.time.limit,
        tokens: state.budgets.tokens.used / state.budgets.tokens.limit,
        cost: state.budgets.cost.used / state.budgets.cost.limit
      },
      memory_usage: :erlang.process_info(self(), :memory),
      message_queue_len: :erlang.process_info(self(), :message_queue_len)
    }

    {:reply, {:ok, health_status}, state}
  end
end
```

## API Reference

### Otto.Agent.start_link/1

Start a new agent process.

```elixir
@spec start_link(Otto.Agent.Config.t()) :: GenServer.on_start()

# Start agent with configuration
config = %Otto.Agent.Config{name: "helper", model: "claude-3-haiku-20240307"}
{:ok, pid} = Otto.Agent.start_link(config)
```

### Otto.Agent.invoke/3

Synchronously invoke an agent with a task.

```elixir
@spec invoke(GenServer.server(), String.t() | Otto.TaskSpec.t(), keyword()) ::
  {:ok, Otto.Agent.Result.t()} | {:error, any()}

# Simple string task
{:ok, result} = Otto.Agent.invoke(pid, "Read the README file and summarize it")

# Complex task specification
task_spec = Otto.TaskSpec.new("Analyze the codebase",
  context: %{focus: "security"},
  tools_allowed: ["fs.read", "grep"],
  max_iterations: 5
)
{:ok, result} = Otto.Agent.invoke(pid, task_spec, timeout: 180_000)
```

### Otto.Agent.get_status/1

Get current agent status and metrics.

```elixir
@spec get_status(GenServer.server()) :: Otto.Agent.Status.t()

status = Otto.Agent.get_status(pid)
# => %Otto.Agent.Status{
#      state: :ready,
#      uptime_ms: 45000,
#      invocation_count: 3,
#      budget_utilization: %{...}
#    }
```

### Otto.Agent.stop/1

Gracefully stop an agent.

```elixir
@spec stop(GenServer.server()) :: :ok

Otto.Agent.stop(pid)
```

---

This comprehensive documentation covers the complete AgentServer API and lifecycle management. For operational guidance and monitoring setup, see the [Operational Guide](operational-guide.md).