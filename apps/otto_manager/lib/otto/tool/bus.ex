defmodule Otto.Tool.Bus do
  @moduledoc """
  GenServer for managing tool registration, permissions, and execution.

  The Tool Bus serves as the central registry for all available tools and their
  permissions. It uses ETS tables for fast lookups and provides a clean API
  for tool management and execution with proper security checks.
  """

  use GenServer
  require Logger

  @type tool_name :: String.t()
  @type agent_id :: String.t()
  @type permission_key :: {agent_id(), tool_name()}

  defstruct [
    :tools_table,
    :permissions_table,
    :name
  ]

  ## Client API

  @doc """
  Starts the Tool Bus GenServer.

  ## Options
  - `:name` - Process name for the GenServer (optional)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a tool with the bus.

  ## Parameters
  - `bus` - GenServer process identifier
  - `name` - Tool name (must be unique)
  - `module` - Module implementing the Otto.Tool behaviour
  """
  @spec register_tool(GenServer.server(), tool_name(), module()) :: :ok | {:error, :already_registered}
  def register_tool(bus, name, module) do
    GenServer.call(bus, {:register_tool, name, module})
  end

  @doc """
  Unregisters a tool from the bus.
  """
  @spec unregister_tool(GenServer.server(), tool_name()) :: :ok | {:error, :not_found}
  def unregister_tool(bus, name) do
    GenServer.call(bus, {:unregister_tool, name})
  end

  @doc """
  Gets a registered tool module by name.
  """
  @spec get_tool(GenServer.server(), tool_name()) :: {:ok, module()} | {:error, :not_found}
  def get_tool(bus, name) do
    GenServer.call(bus, {:get_tool, name})
  end

  @doc """
  Lists all registered tool names.
  """
  @spec list_tools(GenServer.server()) :: [tool_name()]
  def list_tools(bus) do
    GenServer.call(bus, :list_tools)
  end

  @doc """
  Grants permission for an agent to use a tool.
  """
  @spec grant_permission(GenServer.server(), agent_id(), tool_name()) :: :ok
  def grant_permission(bus, agent_id, tool_name) do
    GenServer.call(bus, {:grant_permission, agent_id, tool_name})
  end

  @doc """
  Revokes permission for an agent to use a tool.
  """
  @spec revoke_permission(GenServer.server(), agent_id(), tool_name()) :: :ok
  def revoke_permission(bus, agent_id, tool_name) do
    GenServer.call(bus, {:revoke_permission, agent_id, tool_name})
  end

  @doc """
  Checks if an agent has permission to use a tool.
  """
  @spec check_permission(GenServer.server(), agent_id(), tool_name()) :: :ok | {:error, :permission_denied}
  def check_permission(bus, agent_id, tool_name) do
    GenServer.call(bus, {:check_permission, agent_id, tool_name})
  end

  @doc """
  Executes a tool with the given arguments and context.

  This function handles permission checking, argument validation, and tool execution
  with proper error handling and telemetry.
  """
  @spec execute_tool(GenServer.server(), tool_name(), map(), map()) :: Otto.Tool.result()
  def execute_tool(bus, tool_name, args, context) do
    GenServer.call(bus, {:execute_tool, tool_name, args, context}, 30_000)
  end

  ## Server Implementation

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    tools_table = :ets.new(:"#{name}_tools", [:set, :private])
    permissions_table = :ets.new(:"#{name}_permissions", [:set, :private])

    state = %__MODULE__{
      tools_table: tools_table,
      permissions_table: permissions_table,
      name: name
    }

    Logger.debug("Started Otto.Tool.Bus with name: #{inspect(name)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:register_tool, name, module}, _from, state) do
    case :ets.lookup(state.tools_table, name) do
      [] ->
        # Verify module implements Otto.Tool behaviour
        if function_exported?(module, :execute, 2) and
           function_exported?(module, :validate_args, 1) and
           function_exported?(module, :sandbox_config, 0) do

          :ets.insert(state.tools_table, {name, module})
          Logger.debug("Registered tool: #{name} (#{module})")
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_tool_module}, state}
        end

      [{^name, _module}] ->
        {:reply, {:error, :already_registered}, state}
    end
  end

  @impl true
  def handle_call({:unregister_tool, name}, _from, state) do
    case :ets.lookup(state.tools_table, name) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^name, _module}] ->
        :ets.delete(state.tools_table, name)

        # Clean up permissions for this tool
        :ets.match_delete(state.permissions_table, {{:_, name}})

        Logger.debug("Unregistered tool: #{name}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get_tool, name}, _from, state) do
    case :ets.lookup(state.tools_table, name) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^name, module}] ->
        {:reply, {:ok, module}, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools = :ets.tab2list(state.tools_table)
    |> Enum.map(fn {name, _module} -> name end)
    |> Enum.sort()

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:grant_permission, agent_id, tool_name}, _from, state) do
    :ets.insert(state.permissions_table, {{agent_id, tool_name}})
    Logger.debug("Granted permission: #{agent_id} -> #{tool_name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:revoke_permission, agent_id, tool_name}, _from, state) do
    :ets.delete(state.permissions_table, {agent_id, tool_name})
    Logger.debug("Revoked permission: #{agent_id} -> #{tool_name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:check_permission, agent_id, tool_name}, _from, state) do
    case :ets.lookup(state.permissions_table, {agent_id, tool_name}) do
      [] ->
        {:reply, {:error, :permission_denied}, state}

      [{{^agent_id, ^tool_name}}] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:execute_tool, tool_name, args, context}, _from, state) do
    with {:ok, module} <- get_tool_module(state, tool_name),
         :ok <- check_permission_internal(state, context.agent_id, tool_name),
         :ok <- module.validate_args(args) do

      # Add telemetry
      start_time = System.monotonic_time()

      result = try do
        module.execute(args, context)
      rescue
        error ->
          Logger.error("Tool execution error: #{inspect(error)}")
          {:error, "Tool execution failed: #{Exception.message(error)}"}
      end

      # Emit telemetry (if available)
      duration = System.monotonic_time() - start_time
      try do
        :telemetry.execute([:otto, :tool, :execute], %{duration: duration}, %{
          tool_name: tool_name,
          agent_id: context.agent_id,
          success: match?({:ok, _}, result)
        })
      rescue
        UndefinedFunctionError -> :ok
      end

      {:reply, result, state}
    else
      {:error, :not_found} ->
        {:reply, {:error, :tool_not_found}, state}

      {:error, :permission_denied} = error ->
        {:reply, error, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("Otto.Tool.Bus terminating: #{inspect(reason)}")

    # Clean up ETS tables
    :ets.delete(state.tools_table)
    :ets.delete(state.permissions_table)

    :ok
  end

  ## Private Functions

  defp get_tool_module(state, tool_name) do
    case :ets.lookup(state.tools_table, tool_name) do
      [] -> {:error, :not_found}
      [{^tool_name, module}] -> {:ok, module}
    end
  end

  defp check_permission_internal(state, agent_id, tool_name) do
    case :ets.lookup(state.permissions_table, {agent_id, tool_name}) do
      [] -> {:error, :permission_denied}
      [{{^agent_id, ^tool_name}}] -> :ok
    end
  end
end