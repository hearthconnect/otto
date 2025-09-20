defmodule Otto.Manager.Supervisor do
  @moduledoc """
  Main supervisor for the Otto Manager application.

  This supervisor manages the core components of the Otto system including:
  - Registry for process naming
  - Context Store for ephemeral state
  - Checkpointer for persistence
  - Cost Tracker for usage monitoring
  - Dynamic Supervisor for agent lifecycle
  - Task Supervisor for async operations
  """

  use Supervisor
  require Logger

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = child_specs()

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.init(children, opts)
  end

  @doc """
  Returns the child specifications for all Otto Manager components.
  """
  def child_specs do
    [
      # Registry for process naming using {:via, Registry, {Otto.Registry, {type, id}}}
      {Registry, keys: :unique, name: Otto.Registry},

      # Core state management GenServers
      {Otto.Manager.ContextStore, name: Otto.Manager.ContextStore},
      {Otto.Manager.Checkpointer, name: Otto.Manager.Checkpointer},
      {Otto.Manager.CostTracker, name: Otto.Manager.CostTracker},

      # Dynamic Supervisor for agent lifecycle management
      {DynamicSupervisor,
       name: Otto.Manager.DynamicSupervisor,
       strategy: :one_for_one},

      # Task Supervisor for async operations
      {Task.Supervisor, name: Otto.Manager.TaskSupervisor}
    ]
  end

  @doc """
  Starts a new agent process under the dynamic supervisor.

  ## Parameters
  - `agent_id` - Unique identifier for the agent
  - `agent_spec` - Child specification for the agent process
  """
  def start_agent(agent_id, agent_spec) do
    # Register the agent in the registry with a unique name
    registry_name = {:via, Registry, {Otto.Registry, {:agent, agent_id}}}

    # Add registry name to the agent spec
    updated_spec = Map.put(agent_spec, :name, registry_name)

    case DynamicSupervisor.start_child(Otto.Manager.DynamicSupervisor, updated_spec) do
      {:ok, pid} ->
        Logger.info("Started agent #{agent_id} with pid #{inspect(pid)}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Agent #{agent_id} already running with pid #{inspect(pid)}")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start agent #{agent_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops an agent process.

  ## Parameters
  - `agent_id` - Unique identifier for the agent
  """
  def stop_agent(agent_id) do
    case Registry.lookup(Otto.Registry, {:agent, agent_id}) do
      [{pid, _}] ->
        case DynamicSupervisor.terminate_child(Otto.Manager.DynamicSupervisor, pid) do
          :ok ->
            Logger.info("Stopped agent #{agent_id}")
            :ok

          {:error, reason} = error ->
            Logger.error("Failed to stop agent #{agent_id}: #{inspect(reason)}")
            error
        end

      [] ->
        Logger.debug("Agent #{agent_id} not found")
        {:error, :not_found}
    end
  end

  @doc """
  Lists all running agents.
  """
  def list_agents do
    Registry.select(Otto.Registry, [
      {{{:agent, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc """
  Gets the PID of a running agent.

  ## Parameters
  - `agent_id` - Unique identifier for the agent
  """
  def get_agent_pid(agent_id) do
    case Registry.lookup(Otto.Registry, {:agent, agent_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Runs an async task under the task supervisor.

  ## Parameters
  - `fun` - Function to execute asynchronously
  """
  def async_task(fun) when is_function(fun, 0) do
    Task.Supervisor.async_nolink(Otto.Manager.TaskSupervisor, fun)
  end

  @doc """
  Runs an async task under the task supervisor with a module, function, and arguments.

  ## Parameters
  - `module` - Module containing the function
  - `function` - Function name
  - `args` - List of arguments
  """
  def async_task(module, function, args) do
    Task.Supervisor.async_nolink(Otto.Manager.TaskSupervisor, module, function, args)
  end
end