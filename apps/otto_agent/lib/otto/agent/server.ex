defmodule Otto.Agent.Server do
  @moduledoc """
  GenServer implementation for an Otto AI agent.

  This server manages the agent's lifecycle, handles invocations, tracks budget usage,
  and maintains conversation history. It integrates with the LLM provider for
  generating intelligent responses.
  """

  use GenServer
  require Logger
  alias Otto.Agent.Config

  @session_cleanup_interval 60_000  # 1 minute
  @session_ttl 3_600_000  # 1 hour

  # State structure
  defstruct [
    :session_id,
    :config,
    :budgets,
    :transcript,
    :artifacts,
    :context,
    :status,
    :created_at,
    :last_activity_at
  ]

  @type state :: %__MODULE__{
    session_id: String.t(),
    config: Config.t(),
    budgets: map(),
    transcript: list(),
    artifacts: list(),
    context: map(),
    status: :idle | :busy | :stopping,
    created_at: DateTime.t(),
    last_activity_at: DateTime.t()
  }

  ## Client API

  @doc """
  Starts an Agent server with the given configuration.
  """
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @doc """
  Invokes the agent with a task.
  """
  def invoke(server, task) do
    GenServer.call(server, {:invoke, task}, :infinity)
  end

  @doc """
  Gets the current status of the agent.
  """
  def get_status(server) do
    GenServer.call(server, :get_status)
  end

  @doc """
  Stops the agent server gracefully.
  """
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  ## Server Callbacks

  @impl true
  def init(config) do
    session_id = generate_session_id()
    now = DateTime.utc_now()

    state = %__MODULE__{
      session_id: session_id,
      config: config,
      budgets: init_budgets(config),
      transcript: [],
      artifacts: [],
      context: %{},
      status: :idle,
      created_at: now,
      last_activity_at: now
    }

    Logger.info("Starting AgentServer",
      session_id: session_id,
      agent_name: config.name
    )

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_session, @session_cleanup_interval)

    {:ok, state}
  end

  @impl true
  def handle_call({:invoke, task}, _from, state) do
    state = %{state | status: :busy, last_activity_at: DateTime.utc_now()}

    Logger.info("Agent invocation started",
      session_id: state.session_id,
      task_length: String.length(task)
    )

    # Execute the invocation
    case execute_invocation(task, state) do
      {:ok, result, updated_state} ->
        final_state = %{updated_state | status: :idle, last_activity_at: DateTime.utc_now()}

        Logger.info("Agent invocation completed successfully",
          session_id: state.session_id,
          duration_ms: calculate_duration(state.last_activity_at, final_state.last_activity_at)
        )

        {:reply, {:ok, format_result(result, final_state)}, final_state}

      {:error, reason, error_state} ->
        final_state = %{error_state | status: :idle}
        Logger.error("Agent invocation failed",
          session_id: state.session_id,
          reason: inspect(reason)
        )
        {:reply, {:error, reason}, final_state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    uptime_ms = DateTime.diff(DateTime.utc_now(), state.created_at, :millisecond)

    status = %{
      state: state.status,
      session_id: state.session_id,
      name: state.config.name,
      uptime_ms: uptime_ms,
      budget_usage: %{
        tokens_used: state.budgets.tokens_used || 0,
        cost_used: state.budgets.cost_used || 0.0,
        time_remaining: state.budgets.time_remaining || 0
      },
      transcript_length: length(state.transcript),
      last_activity: state.last_activity_at
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:cleanup_session, state) do
    # Check if session is stale
    if DateTime.diff(DateTime.utc_now(), state.last_activity_at, :millisecond) > @session_ttl do
      Logger.info("Session expired, stopping agent",
        session_id: state.session_id
      )
      {:stop, :normal, state}
    else
      # Schedule next cleanup
      Process.send_after(self(), :cleanup_session, @session_cleanup_interval)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received unexpected message",
      session_id: state.session_id,
      message: inspect(msg)
    )
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("AgentServer terminating",
      session_id: state.session_id,
      reason: inspect(reason)
    )
    :ok
  end

  ## Private Functions

  defp generate_session_id do
    "session_#{System.system_time(:millisecond)}_#{:rand.uniform(99999)}"
  end

  defp init_budgets(config) do
    budgets = config.budgets || %{}

    %{
      time_remaining: Map.get(budgets, :time_seconds, 300) * 1000,
      max_tokens: Map.get(budgets, :max_tokens, 10000),
      tokens_used: 0,
      max_cost: Map.get(budgets, :max_cost_dollars, 1.0),
      cost_used: 0.0
    }
  end

  defp execute_invocation(task, state) do
    # Add user input to transcript
    user_entry = %{
      type: :user_input,
      timestamp: DateTime.utc_now(),
      content: task
    }

    updated_transcript = [user_entry | state.transcript]
    state = %{state | transcript: updated_transcript}

    # Use real LLM integration
    case invoke_llm(task, state) do
      {:ok, llm_response, updated_state} ->
        result = %{
          output: llm_response.content,
          artifacts: updated_state.artifacts,
          transcript: Enum.reverse(updated_state.transcript),
          budget_status: %{
            time_remaining: updated_state.budgets.time_remaining,
            tokens_used: updated_state.budgets.tokens_used,
            cost_used: updated_state.budgets.cost_used
          },
          success: true
        }

        {:ok, result, updated_state}

      {:error, reason} ->
        Logger.error("LLM invocation failed",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        # Fallback to error response
        error_response = "I'm sorry, I encountered an error processing your request: #{inspect(reason)}"

        response_entry = %{
          type: :agent_output,
          timestamp: DateTime.utc_now(),
          content: error_response
        }

        final_transcript = [response_entry | updated_transcript]
        final_state = %{state | transcript: final_transcript}

        result = %{
          output: error_response,
          artifacts: final_state.artifacts,
          transcript: Enum.reverse(final_transcript),
          budget_status: %{
            time_remaining: final_state.budgets.time_remaining,
            tokens_used: final_state.budgets.tokens_used,
            cost_used: final_state.budgets.cost_used
          },
          success: false
        }

        {:ok, result, final_state}
    end
  end

  defp record_token_usage(state, token_count) do
    updated_budgets = Map.update!(state.budgets, :tokens_used, &(&1 + token_count))
    %{state | budgets: updated_budgets}
  end

  defp record_cost_usage(state, cost) do
    updated_budgets = Map.update!(state.budgets, :cost_used, &(&1 + cost))
    %{state | budgets: updated_budgets}
  end

  defp format_result(result, state) do
    %{
      output: result.output,
      artifacts: result.artifacts,
      transcript: result.transcript,
      budget_status: %{
        time_remaining: state.budgets.time_remaining,
        tokens_used: state.budgets.tokens_used,
        cost_used: state.budgets.cost_used
      },
      success: result.success
    }
  end

  # LLM Integration

  @spec invoke_llm(String.t(), state()) :: {:ok, map(), state()} | {:error, term()}
  defp invoke_llm(user_input, state) do
    # Build conversation messages including system prompt
    messages = build_conversation_messages(user_input, state)

    # Get model from config with fallback
    model = state.config.model || "gpt-3.5-turbo"

    # Set up LLM options based on budget constraints
    llm_opts = [
      max_tokens: calculate_max_tokens(state),
      temperature: 0.7
    ]

    Logger.info("Invoking LLM",
      session_id: state.session_id,
      model: model,
      message_count: length(messages)
    )

    case Otto.LLM.chat(model, messages, llm_opts) do
      {:ok, llm_response} ->
        # Update budget tracking with actual token usage
        updated_state =
          state
          |> record_token_usage(llm_response.usage.total_tokens)
          |> record_cost_usage(calculate_cost(llm_response, model))

        # Add LLM response to transcript
        response_entry = %{
          type: :agent_output,
          timestamp: DateTime.utc_now(),
          content: llm_response.content,
          model: llm_response.model,
          token_usage: llm_response.usage
        }

        final_transcript = [response_entry | updated_state.transcript]
        final_state = %{updated_state | transcript: final_transcript}

        {:ok, llm_response, final_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_conversation_messages(user_input, state) do
    # Start with system prompt
    system_message = %{
      role: "system",
      content: state.config.system_prompt
    }

    # Add conversation history from transcript (last 10 exchanges to stay within context)
    history_messages =
      state.transcript
      |> Enum.reverse()
      |> Enum.take(20) # Take last 20 entries (10 user + 10 assistant)
      |> Enum.filter(fn entry -> entry.type in [:user_input, :agent_output] end)
      |> Enum.map(fn entry ->
        case entry.type do
          :user_input -> %{role: "user", content: entry.content}
          :agent_output -> %{role: "assistant", content: entry.content}
        end
      end)

    # Add current user input
    current_message = %{role: "user", content: user_input}

    [system_message] ++ history_messages ++ [current_message]
  end

  defp calculate_max_tokens(state) do
    # Calculate remaining tokens based on budget
    max_budget_tokens = state.budgets[:max_tokens] || 1000
    used_tokens = state.budgets.tokens_used || 0
    remaining = max_budget_tokens - used_tokens

    # Reserve some tokens for the response, don't use all budget on one call
    max(min(remaining, 1000), 100)
  end

  defp calculate_cost(llm_response, model) do
    # Simple cost calculation - would be more sophisticated in production
    # OpenAI pricing as of 2024 (approximate)
    {input_cost_per_token, output_cost_per_token} = case model do
      "gpt-4" -> {0.00003, 0.00006}
      "gpt-3.5-turbo" -> {0.0000005, 0.0000015}
      _ -> {0.000001, 0.000002} # fallback
    end

    input_cost = llm_response.usage.prompt_tokens * input_cost_per_token
    output_cost = llm_response.usage.completion_tokens * output_cost_per_token
    input_cost + output_cost
  end

  defp calculate_duration(start_time, end_time) do
    DateTime.diff(end_time, start_time, :millisecond)
  end
end