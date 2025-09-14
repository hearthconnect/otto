defmodule Otto.Agent.Server do
  @moduledoc """
  Main orchestrator GenServer for agent invocations.

  Handles:
  - Budget enforcement (time, tokens, cost limits)
  - Transcript capture and artifact management
  - Integration with ContextStore and Checkpointer
  - Tool invocation coordination
  """

  use GenServer
  require Logger

  alias Otto.Agent.Config

  defstruct [
    :config,
    :session_id,
    :start_time,
    :transcript,
    :budgets,
    :artifacts,
    :tool_bus
  ]

  @type state :: %__MODULE__{
    config: Config.t(),
    session_id: String.t(),
    start_time: DateTime.t(),
    transcript: [map()],
    budgets: %{
      time_remaining: non_neg_integer(),
      tokens_used: non_neg_integer(),
      cost_used: float()
    },
    artifacts: map(),
    tool_bus: pid()
  }

  @type invocation_request :: %{
    input: String.t(),
    context: map(),
    options: keyword()
  }

  @type invocation_result :: %{
    output: String.t(),
    artifacts: map(),
    transcript: [map()],
    budget_status: map(),
    success: boolean()
  }

  # Client API

  @doc """
  Starts an AgentServer with the given configuration.

  ## Options

  - `:session_id` - Unique identifier for this session (defaults to UUID)
  - `:tool_bus` - PID of the tool bus process (optional)

  ## Examples

      {:ok, pid} = Otto.Agent.Server.start_link(config, session_id: "test-123")
  """
  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(%Config{} = config, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())
    tool_bus = Keyword.get(opts, :tool_bus)

    GenServer.start_link(__MODULE__, {config, session_id, tool_bus}, opts)
  end

  @doc """
  Invokes the agent with the given request.

  Returns the result of the invocation including output, artifacts,
  and budget status.
  """
  @spec invoke(GenServer.server(), invocation_request()) ::
    {:ok, invocation_result()} | {:error, term()}
  def invoke(server, request) do
    GenServer.call(server, {:invoke, request}, :infinity)
  end

  @doc """
  Gets the current state of the agent session.
  """
  @spec get_state(GenServer.server()) :: {:ok, state()}
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Stops the agent server gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # Server Callbacks

  @impl true
  def init({%Config{} = config, session_id, tool_bus}) do
    Logger.info("Starting AgentServer", session_id: session_id, agent_name: config.name)

    state = %__MODULE__{
      config: config,
      session_id: session_id,
      start_time: DateTime.utc_now(),
      transcript: [],
      budgets: initialize_budgets(config.budgets),
      artifacts: %{},
      tool_bus: tool_bus
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:invoke, request}, _from, state) do
    Logger.info("Agent invocation started",
      session_id: state.session_id,
      input_length: String.length(request.input)
    )

    case check_budgets(state) do
      {:ok, state} ->
        case execute_invocation(request, state) do
          {:ok, result, new_state} ->
            Logger.info("Agent invocation completed successfully",
              session_id: state.session_id,
              output_length: String.length(result.output)
            )
            {:reply, {:ok, result}, new_state}
        end

      {:error, budget_error} ->
        Logger.warning("Budget exceeded",
          session_id: state.session_id,
          budget_error: budget_error
        )
        {:reply, {:error, {:budget_exceeded, budget_error}}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:check_timeout, state) do
    case check_time_budget(state) do
      {:ok, _} ->
        # Schedule next timeout check
        Process.send_after(self(), :check_timeout, 5_000)
        {:noreply, state}

      {:error, :time_budget_exceeded} ->
        Logger.warning("Time budget exceeded, stopping agent", session_id: state.session_id)
        {:stop, :normal, state}
    end
  end

  # Private Functions

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp initialize_budgets(budget_config) do
    %{
      time_remaining: Map.get(budget_config, :time_seconds, :infinity),
      tokens_used: 0,
      cost_used: 0.0,
      max_tokens: Map.get(budget_config, :max_tokens, :infinity),
      max_cost_dollars: Map.get(budget_config, :max_cost_dollars, :infinity)
    }
  end

  defp check_budgets(state) do
    with {:ok, state} <- check_time_budget(state),
         {:ok, state} <- check_token_budget(state),
         {:ok, state} <- check_cost_budget(state) do
      {:ok, state}
    end
  end

  defp check_time_budget(%{budgets: %{time_remaining: :infinity}} = state) do
    {:ok, state}
  end

  defp check_time_budget(%{budgets: budgets, start_time: start_time} = state) do
    elapsed_seconds = DateTime.diff(DateTime.utc_now(), start_time)
    remaining = budgets.time_remaining - elapsed_seconds

    if remaining > 0 do
      updated_budgets = %{budgets | time_remaining: remaining}
      {:ok, %{state | budgets: updated_budgets}}
    else
      {:error, :time_budget_exceeded}
    end
  end

  defp check_token_budget(%{budgets: %{max_tokens: :infinity}} = state) do
    {:ok, state}
  end

  defp check_token_budget(%{budgets: budgets} = state) do
    if budgets.tokens_used < budgets.max_tokens do
      {:ok, state}
    else
      {:error, :token_budget_exceeded}
    end
  end

  defp check_cost_budget(%{budgets: %{max_cost_dollars: :infinity}} = state) do
    {:ok, state}
  end

  defp check_cost_budget(%{budgets: budgets} = state) do
    if budgets.cost_used < budgets.max_cost_dollars do
      {:ok, state}
    else
      {:error, :cost_budget_exceeded}
    end
  end

  defp execute_invocation(request, state) do
    # Add request to transcript
    transcript_entry = %{
      type: :user_input,
      timestamp: DateTime.utc_now(),
      content: request.input,
      context: Map.get(request, :context, %{})
    }

    updated_transcript = [transcript_entry | state.transcript]
    state = %{state | transcript: updated_transcript}

    # For now, implement a simple echo response
    # This will be expanded to include actual LLM integration
    result = %{
      output: "Agent #{state.config.name} received: #{request.input}",
      artifacts: state.artifacts,
      transcript: Enum.reverse(updated_transcript),
      budget_status: %{
        time_remaining: state.budgets.time_remaining,
        tokens_used: state.budgets.tokens_used,
        cost_used: state.budgets.cost_used
      },
      success: true
    }

    # Add response to transcript
    response_entry = %{
      type: :agent_output,
      timestamp: DateTime.utc_now(),
      content: result.output
    }

    final_transcript = [response_entry | updated_transcript]
    final_state = %{state | transcript: final_transcript}

    {:ok, result, final_state}
  end

  defp record_token_usage(state, token_count) do
    updated_budgets = %{state.budgets | tokens_used: state.budgets.tokens_used + token_count}
    %{state | budgets: updated_budgets}
  end

  defp record_cost_usage(state, cost) do
    updated_budgets = %{state.budgets | cost_used: state.budgets.cost_used + cost}
    %{state | budgets: updated_budgets}
  end

  @doc """
  Validates tool permissions and invokes a tool if allowed.

  This will integrate with the ToolBus for actual tool execution.
  """
  @spec invoke_tool(state(), String.t(), map()) :: {:ok, term(), state()} | {:error, term(), state()}
  def invoke_tool(state, tool_name, args) do
    if tool_name in state.config.tools do
      # TODO: Integrate with actual ToolBus
      Logger.info("Tool invocation",
        session_id: state.session_id,
        tool: tool_name,
        args: inspect(args, limit: :infinity)
      )

      # Mock result for now
      result = %{tool: tool_name, result: "Mock result", args: args}

      # Add to transcript
      tool_entry = %{
        type: :tool_invocation,
        timestamp: DateTime.utc_now(),
        tool: tool_name,
        args: args,
        result: result
      }

      updated_transcript = [tool_entry | state.transcript]
      updated_state = %{state | transcript: updated_transcript}

      {:ok, result, updated_state}
    else
      {:error, {:tool_not_allowed, tool_name}, state}
    end
  end
end