defmodule Otto.AgentServer do
  @moduledoc """
  GenServer for managing individual Otto agent instances.

  Each agent runs in its own process with isolated context, budget tracking,
  and transcript management. Provides the core runtime for agent execution.
  """

  use GenServer
  require Logger
  alias Otto.AgentConfig
  alias Otto.ToolContext

  @default_transcript_limit 100
  @default_working_dir_base "/tmp/otto/agents"

  defstruct [
    :config,
    :session_id,
    :started_at,
    :transcript,
    :budget_status,
    :invocation_count,
    :working_dir
  ]

  @type task_spec :: %{
          instruction: String.t(),
          context: map(),
          options: keyword()
        }

  ## Client API

  @doc "Starts an agent server with the given configuration"
  def start_link(%AgentConfig{} = config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @doc "Invokes the agent with a task specification"
  def invoke(pid, %{} = task_spec) do
    GenServer.call(pid, {:invoke, task_spec}, :timer.minutes(10))
  end

  @doc "Gets the agent's current status"
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @doc "Gets the agent's configuration"
  def get_config(pid) do
    GenServer.call(pid, :get_config)
  end

  @doc "Gets the current transcript"
  def get_transcript(pid) do
    GenServer.call(pid, :get_transcript)
  end

  @doc "Gets current budget status"
  def get_budget_status(pid) do
    GenServer.call(pid, :get_budget_status)
  end

  ## Server Implementation

  @impl true
  def init(%AgentConfig{} = config) do
    session_id = generate_session_id()
    started_at = DateTime.utc_now()
    working_dir = create_working_directory(session_id)

    budget_status = %{
      time_remaining: config.budgets[:time_limit] || 300,
      tokens_used: 0,
      cost_used: 0.0,
      budget_exceeded: false
    }

    state = %__MODULE__{
      config: config,
      session_id: session_id,
      started_at: started_at,
      transcript: [],
      budget_status: budget_status,
      invocation_count: 0,
      working_dir: working_dir
    }

    # Set up timer for budget countdown
    schedule_budget_check()

    Logger.info("Agent server started", agent: config.name, session_id: session_id)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  @impl true
  def handle_call(:get_transcript, _from, state) do
    {:reply, state.transcript, state}
  end

  @impl true
  def handle_call(:get_budget_status, _from, state) do
    {:reply, state.budget_status, state}
  end

  @impl true
  def handle_call(:get_invocation_count, _from, state) do
    {:reply, state.invocation_count, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      config: state.config,
      session_id: state.session_id,
      started_at: state.started_at,
      budget_status: state.budget_status,
      transcript_length: length(state.transcript),
      invocation_count: state.invocation_count,
      working_dir: state.working_dir
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:create_tool_context, _from, state) do
    context = %ToolContext{
      agent_config: state.config,
      working_dir: state.working_dir,
      budget_guard: %{
        remaining: max(0, (state.config.budgets[:cost_limit] || 1.0) - state.budget_status.cost_used)
      },
      session_id: state.session_id,
      metadata: %{
        invocation_count: state.invocation_count,
        started_at: state.started_at
      }
    }
    {:reply, context, state}
  end

  @impl true
  def handle_call({:invoke, task_spec}, _from, state) do
    if state.budget_status.budget_exceeded do
      {:reply, {:error, :budget_exceeded}, state}
    else
      case execute_invocation(task_spec, state) do
        {:ok, result, new_state} ->
          {:reply, {:ok, result}, new_state}
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_cast({:add_to_transcript, message}, state) do
    new_transcript = add_message_to_transcript(state.transcript, message)
    {:noreply, %{state | transcript: new_transcript}}
  end

  @impl true
  def handle_cast({:update_budget, budget_update}, state) do
    new_budget_status = Map.merge(state.budget_status, budget_update)
    {:noreply, %{state | budget_status: new_budget_status}}
  end

  @impl true
  def handle_info(:budget_check, state) do
    new_budget_status = update_time_budget(state.budget_status, state.started_at)

    if new_budget_status.budget_exceeded and not state.budget_status.budget_exceeded do
      Logger.warning("Time budget exceeded, stopping agent", session_id: state.session_id)
      # Could implement graceful shutdown here
    end

    schedule_budget_check()
    {:noreply, %{state | budget_status: new_budget_status}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Agent server terminating",
      reason: reason,
      session_id: state.session_id,
      agent: state.config.name
    )

    # Cleanup working directory
    cleanup_working_directory(state.working_dir)
    :ok
  end

  ## Private Functions

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp create_working_directory(session_id) do
    working_dir = Path.join([@default_working_dir_base, session_id])
    File.mkdir_p!(working_dir)
    working_dir
  end

  defp cleanup_working_directory(working_dir) do
    if File.exists?(working_dir) do
      File.rm_rf(working_dir)
    end
  end

  defp execute_invocation(task_spec, state) do
    # This is a placeholder for the actual invocation logic
    # In a full implementation, this would:
    # 1. Create LLM request with system prompt + task
    # 2. Stream response and handle tool calls
    # 3. Execute tools and continue conversation
    # 4. Return final result

    Logger.info("Executing invocation",
      session_id: state.session_id,
      instruction: task_spec[:instruction]
    )

    # Mock successful execution
    result = %{
      success: true,
      output: "Mock response to: #{task_spec[:instruction] || "unnamed task"}",
      transcript: state.transcript,
      artifacts: [],
      budget_status: state.budget_status
    }

    new_state = %{state | invocation_count: state.invocation_count + 1}

    {:ok, result, new_state}
  end

  defp add_message_to_transcript(transcript, message) do
    new_transcript = transcript ++ [Map.put(message, :timestamp, DateTime.utc_now())]

    # Keep transcript bounded
    if length(new_transcript) > @default_transcript_limit do
      Enum.drop(new_transcript, length(new_transcript) - @default_transcript_limit)
    else
      new_transcript
    end
  end

  defp update_time_budget(budget_status, started_at) do
    time_limit = budget_status[:time_limit] || 300  # Default 5 minutes
    elapsed = DateTime.diff(DateTime.utc_now(), started_at)
    time_remaining = max(0, time_limit - elapsed)

    %{budget_status | time_remaining: time_remaining, budget_exceeded: time_remaining <= 0}
  end

  defp schedule_budget_check do
    Process.send_after(self(), :budget_check, 1000)  # Check every second
  end
end