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
  def handle_call({:invoke, request}, _from, state) when is_map(request) do
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
  def handle_call(:get_status, _from, state) do
    uptime_ms = DateTime.diff(DateTime.utc_now(), state.start_time, :millisecond)

    status = %{
      state: :idle,  # TODO: track actual state (idle/busy)
      session_id: state.session_id,
      uptime_ms: uptime_ms,
      budget_usage: calculate_budget_usage(state),
      tool_calls: length(state.transcript),
      name: state.config.name
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:invoke, task}, from, state) when is_binary(task) do
    # Convert simple string task to the expected request format
    request = %{
      input: task,
      context: %{},
      options: []
    }
    handle_call({:invoke, request}, from, state)
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

    # Use real LLM integration
    case invoke_llm(request.input, state) do
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
    updated_budgets = %{state.budgets | tokens_used: state.budgets.tokens_used + token_count}
    %{state | budgets: updated_budgets}
  end

  defp record_cost_usage(state, cost) do
    updated_budgets = %{state.budgets | cost_used: state.budgets.cost_used + cost}
    %{state | budgets: updated_budgets}
  end

  defp calculate_budget_usage(state) do
    %{
      time_used: DateTime.diff(DateTime.utc_now(), state.start_time, :second),
      tokens_used: state.budgets.tokens_used,
      cost_used: state.budgets.cost_used,
      time_limit: state.config.budgets[:time_seconds],
      token_limit: state.config.budgets[:max_tokens],
      cost_limit: state.config.budgets[:max_cost_dollars]
    }
  end

  # LLM Integration

  @spec invoke_llm(String.t(), state()) :: {:ok, map(), state()} | {:error, term()}
  defp invoke_llm(user_input, state) do
    # Build conversation messages including system prompt
    messages = build_conversation_messages(user_input, state)

    # Get model from config with fallback
    model = state.config.model || "gpt-3.5-turbo"

    # Build function schemas for available tools
    function_schemas = build_function_schemas(state.config.tools)

    # Set up LLM options based on budget constraints
    llm_opts = [
      max_tokens: calculate_max_tokens(state),
      temperature: 0.7,
      functions: function_schemas
    ]

    Logger.info("Invoking LLM",
      session_id: state.session_id,
      model: model,
      message_count: length(messages),
      tools_available: length(function_schemas)
    )

    case Otto.LLM.chat(model, messages, llm_opts) do
      {:ok, llm_response} ->
        # Handle potential function calls
        case Map.get(llm_response, :function_call) do
          nil ->
            # Regular text response
            handle_text_response(llm_response, state)

          function_call ->
            # Function call response - execute tool and continue conversation
            handle_function_call(function_call, llm_response, user_input, state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_text_response(llm_response, state) do
    # Update budget tracking with actual token usage
    updated_state =
      state
      |> record_token_usage(llm_response.usage.total_tokens)
      |> record_cost_usage(calculate_cost(llm_response, state.config.model || "gpt-3.5-turbo"))

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
  end

  defp handle_function_call(function_call, llm_response, original_input, state) do
    # Update state with initial LLM usage
    updated_state =
      state
      |> record_token_usage(llm_response.usage.total_tokens)
      |> record_cost_usage(calculate_cost(llm_response, state.config.model || "gpt-3.5-turbo"))

    # Parse function arguments
    case Jason.decode(function_call.arguments) do
      {:ok, args} ->
        # Execute the tool
        case invoke_tool(updated_state, function_call.name, args) do
          {:ok, tool_result, tool_updated_state} ->
            # Add function call and result to conversation history
            function_messages = [
              %{
                role: "assistant",
                content: nil,
                function_call: %{
                  name: function_call.name,
                  arguments: function_call.arguments
                }
              },
              %{
                role: "function",
                name: function_call.name,
                content: Jason.encode!(tool_result)
              }
            ]

            # Continue conversation with function result
            continue_after_function_call(function_messages, original_input, tool_updated_state)

          {:error, tool_error, error_state} ->
            # Handle tool execution error gracefully
            error_content = "I encountered an error while using the #{function_call.name} tool: #{inspect(tool_error)}"

            error_response = %{
              content: error_content,
              model: llm_response.model,
              usage: llm_response.usage,
              finish_reason: "tool_error"
            }

            handle_text_response(error_response, error_state)
        end

      {:error, json_error} ->
        # Handle JSON parsing error
        error_content = "I received invalid arguments for the #{function_call.name} tool: #{inspect(json_error)}"

        error_response = %{
          content: error_content,
          model: llm_response.model,
          usage: llm_response.usage,
          finish_reason: "argument_error"
        }

        handle_text_response(error_response, updated_state)
    end
  end

  defp continue_after_function_call(function_messages, original_input, state) do
    # Build complete conversation including function call/result
    base_messages = build_conversation_messages(original_input, state)
    messages = base_messages ++ function_messages

    model = state.config.model || "gpt-3.5-turbo"

    llm_opts = [
      max_tokens: calculate_max_tokens(state),
      temperature: 0.7
    ]

    case Otto.LLM.chat(model, messages, llm_opts) do
      {:ok, final_response} ->
        handle_text_response(final_response, state)

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

  defp build_function_schemas(tool_names) do
    # Get tool information from Tool.Bus (from manager app)
    tool_names
    |> Enum.map(&Otto.Tool.Bus.get_tool(Otto.Tool.Bus, &1))
    |> Enum.filter(fn
      {:ok, _tool_metadata} -> true
      {:error, _} -> false
    end)
    |> Enum.map(fn {:ok, tool_metadata} -> build_function_schema_from_metadata(tool_metadata) end)
  end

  defp build_function_schema_from_metadata(tool_metadata) do
    # Create OpenAI function schema from tool metadata
    %{
      name: tool_metadata.name,
      description: tool_metadata.description,
      parameters: tool_metadata.parameters
    }
  end


  @doc """
  Validates tool permissions and invokes a tool if allowed.

  This integrates with the ToolBus for actual tool execution.
  """
  @spec invoke_tool(state(), String.t(), map()) :: {:ok, term(), state()} | {:error, term(), state()}
  def invoke_tool(state, tool_name, args) do
    if tool_name in state.config.tools do
      Logger.info("Tool invocation",
        session_id: state.session_id,
        tool: tool_name,
        args: inspect(args, limit: :infinity)
      )

      # Create tool context
      tool_context = Otto.ToolContext.new(
        state.config,
        state.config.working_dir,
        state.budgets,
        session_id: state.session_id
      )

      # Execute tool via Tool.Bus
      case Otto.Tool.Bus.execute_tool(Otto.Tool.Bus, tool_name, args, tool_context) do
        {:ok, result} ->
          Logger.info("Tool execution successful",
            session_id: state.session_id,
            tool: tool_name,
            result_type: get_result_type(result)
          )

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

        {:error, reason} ->
          Logger.warning("Tool execution failed",
            session_id: state.session_id,
            tool: tool_name,
            reason: inspect(reason)
          )

          {:error, reason, state}
      end
    else
      Logger.warning("Tool not allowed",
        session_id: state.session_id,
        tool: tool_name,
        allowed_tools: state.config.tools
      )

      {:error, {:tool_not_allowed, tool_name}, state}
    end
  end

  defp get_result_type(result) when is_binary(result), do: "string"
  defp get_result_type(result) when is_map(result), do: "map"
  defp get_result_type(result) when is_list(result), do: "list"
  defp get_result_type(_result), do: "other"
end