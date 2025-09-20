defmodule Otto.Agent do
  @moduledoc """
  Main API for Otto AI agents.

  This module provides the high-level interface for creating, starting, and
  interacting with AI agents. Agents are configured via YAML files and can
  execute various tools within a sandboxed environment.

  ## Basic Usage

      # Load and start an agent from YAML configuration
      {:ok, agent} = Otto.Agent.start_agent("helper")

      # Invoke the agent with a task
      {:ok, result} = Otto.Agent.invoke(agent, "Read the README file and summarize it")

      # Access the result
      IO.puts(result.content)

  ## Configuration

  Agents are configured via YAML files in the `.otto/agents/` directory:

      # .otto/agents/helper.yaml
      name: "helper"
      system_prompt: "You are a helpful coding assistant"
      tools: ["fs.read", "fs.write", "grep"]
      working_dir: "."
      budgets:
        time_seconds: 300
        max_tokens: 10000
        max_cost_dollars: 1.0
  """

  alias Otto.Agent.{Config, Server}

  @type agent_ref :: pid() | atom()
  @type invoke_result :: %{
    content: String.t(),
    artifacts: [map()],
    cost: map(),
    duration_ms: integer()
  }

  @doc """
  Starts an agent from a YAML configuration file.

  Looks for the configuration file in `.otto/agents/{agent_name}.yaml` or
  `.otto/agents/{agent_name}.yml`.

  ## Parameters

  - `agent_name` - Name of the agent (without .yaml extension)
  - `opts` - Optional keyword list of options:
    - `:config_dir` - Directory to look for config files (default: ".otto/agents")
    - `:working_dir` - Override working directory from config

  ## Examples

      {:ok, agent} = Otto.Agent.start_agent("helper")
      {:ok, agent} = Otto.Agent.start_agent("code-reviewer", config_dir: "custom/agents")

  ## Returns

  - `{:ok, agent_pid}` - Agent started successfully
  - `{:error, :config_not_found}` - Configuration file not found
  - `{:error, reason}` - Other error (invalid config, startup failure, etc.)
  """
  @spec start_agent(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(agent_name, opts \\ []) do
    config_dir = Keyword.get(opts, :config_dir, ".otto/agents")
    working_dir_override = Keyword.get(opts, :working_dir)

    with {:ok, config_path} <- find_config_file(agent_name, config_dir),
         {:ok, config} <- Config.load_from_file(config_path),
         {:ok, final_config} <- apply_overrides(config, working_dir_override),
         {:ok, agent_id} <- generate_agent_id(agent_name),
         {:ok, pid} <- start_agent_server(agent_id, final_config) do
      {:ok, pid}
    else
      error -> error
    end
  end

  @doc """
  Starts an agent from a configuration struct.

  ## Parameters

  - `config` - Otto.Agent.Config struct
  - `agent_id` - Optional agent ID (generated if not provided)

  ## Examples

      config = %Otto.Agent.Config{
        name: "custom",
        system_prompt: "You are helpful",
        tools: ["fs.read"],
        working_dir: "."
      }
      {:ok, agent} = Otto.Agent.start_agent_from_config(config)
  """
  @spec start_agent_from_config(Config.t(), String.t() | nil) :: {:ok, pid()} | {:error, term()}
  def start_agent_from_config(config, agent_id \\ nil) do
    agent_id = agent_id || generate_agent_id(config.name)
    start_agent_server(agent_id, config)
  end

  @doc """
  Invokes an agent with a task.

  ## Parameters

  - `agent` - Agent PID or registered name
  - `task` - Task description string
  - `opts` - Optional keyword list:
    - `:timeout` - Timeout in milliseconds (default: 30_000)
    - `:stream` - Whether to stream responses (default: false)

  ## Examples

      {:ok, result} = Otto.Agent.invoke(agent, "Analyze the main.ex file")

      # With streaming
      {:ok, stream} = Otto.Agent.invoke(agent, "Long task", stream: true)
      for chunk <- stream do
        IO.write(chunk.content)
      end

  ## Returns

  - `{:ok, result}` - Task completed successfully
  - `{:error, :timeout}` - Task exceeded time limit
  - `{:error, :budget_exceeded}` - Budget limits exceeded
  - `{:error, reason}` - Other error
  """
  @spec invoke(agent_ref(), String.t(), keyword()) :: {:ok, invoke_result()} | {:error, term()}
  def invoke(agent, task, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    stream = Keyword.get(opts, :stream, false)

    if stream do
      invoke_streaming(agent, task, timeout)
    else
      invoke_sync(agent, task, timeout)
    end
  end

  @doc """
  Stops an agent gracefully.

  ## Parameters

  - `agent` - Agent PID or registered name

  ## Examples

      :ok = Otto.Agent.stop_agent(agent)
  """
  @spec stop_agent(agent_ref()) :: :ok
  def stop_agent(agent) do
    GenServer.stop(agent, :normal)
  end

  @doc """
  Gets the current status of an agent.

  ## Parameters

  - `agent` - Agent PID or registered name

  ## Returns

  Status map containing:
  - `:state` - Current state (:idle, :busy, :stopping)
  - `:session_id` - Current session ID
  - `:uptime_ms` - Uptime in milliseconds
  - `:budget_usage` - Current budget usage
  - `:tool_calls` - Number of tool calls made

  ## Examples

      {:ok, status} = Otto.Agent.get_status(agent)
      IO.inspect(status.budget_usage)
  """
  @spec get_status(agent_ref()) :: {:ok, map()} | {:error, term()}
  def get_status(agent) do
    try do
      status = GenServer.call(agent, :get_status)
      {:ok, status}
    catch
      :exit, reason -> {:error, {:agent_down, reason}}
    end
  end

  @doc """
  Lists all currently running agents.

  ## Returns

  List of agent information maps, each containing:
  - `:agent_id` - Agent identifier
  - `:pid` - Process ID
  - `:name` - Agent name from config
  - `:state` - Current state

  ## Examples

      agents = Otto.Agent.list_agents()
      Enum.each(agents, fn agent ->
        IO.puts("Agent " <> agent.name <> " (" <> agent.agent_id <> "): " <> to_string(agent.state))
      end)
  """
  @spec list_agents() :: [map()]
  def list_agents do
    # Use Registry.select with the correct match specification for Registry entries
    # Pattern: [{{key, pid, value}, guards, result}]
    case Registry.select(Otto.Registry, [{{{:agent, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]) do
      entries when is_list(entries) ->
        entries
        |> Enum.map(fn {agent_id, pid} ->
          case get_status(pid) do
            {:ok, status} ->
              %{
                agent_id: agent_id,
                pid: pid,
                name: status[:name] || "unknown",
                state: status[:state] || :unknown
              }
            {:error, _} ->
              %{
                agent_id: agent_id,
                pid: pid,
                name: "unknown",
                state: :error
              }
          end
        end)
      _ ->
        []
    end
  end

  ## Private Functions

  defp find_config_file(agent_name, config_dir) do
    yaml_path = Path.join(config_dir, "#{agent_name}.yaml")
    yml_path = Path.join(config_dir, "#{agent_name}.yml")

    cond do
      File.exists?(yaml_path) -> {:ok, yaml_path}
      File.exists?(yml_path) -> {:ok, yml_path}
      true -> {:error, :config_not_found}
    end
  end

  defp apply_overrides(config, nil), do: {:ok, config}
  defp apply_overrides(config, working_dir) do
    {:ok, %{config | working_dir: working_dir}}
  end

  defp generate_agent_id(base_name) do
    timestamp = System.system_time(:millisecond)
    random = :rand.uniform(9999)
    {:ok, "#{base_name}_#{timestamp}_#{random}"}
  end

  defp start_agent_server(agent_id, config) do
    # Use the Manager supervisor to start the agent
    child_spec = %{
      id: {:agent, agent_id},
      start: {Server, :start_link, [config, [name: {:via, Registry, {Otto.Registry, {:agent, agent_id}}}]]},
      restart: :transient,
      type: :worker
    }

    case DynamicSupervisor.start_child(Otto.Manager.DynamicSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp invoke_sync(agent, task, timeout) do
    start_time = System.monotonic_time(:millisecond)

    try do
      case GenServer.call(agent, {:invoke, task}, timeout) do
        {:ok, server_result} ->
          end_time = System.monotonic_time(:millisecond)
          duration_ms = end_time - start_time

          # Transform server result to match Otto.Agent API format
          result = %{
            content: server_result.output,
            artifacts: [],
            cost: %{
              tokens_used: get_in(server_result, [:budget_status, :tokens_used]) || 0,
              cost_used: get_in(server_result, [:budget_status, :cost_used]) || 0.0
            },
            duration_ms: duration_ms
          }
          {:ok, result}
        error -> error
      end
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, {:agent_down, reason}}
    end
  end

  defp invoke_streaming(agent, task, timeout) do
    # For now, return a simple implementation
    # In a full implementation, this would set up a stream
    case invoke_sync(agent, task, timeout) do
      {:ok, result} ->
        stream = Stream.unfold(result, fn
          nil -> nil
          result -> {result, nil}
        end)
        {:ok, stream}
      error -> error
    end
  end

end
