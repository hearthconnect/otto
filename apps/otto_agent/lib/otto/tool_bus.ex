defmodule Otto.ToolBus do
  @moduledoc """
  Registry and execution engine for Otto tools.

  The ToolBus maintains a registry of available tools and provides a unified
  interface for tool invocation with permission checking and context management.
  """

  use GenServer
  require Logger

  defstruct tools: %{}

  @type tool_info :: %{
          name: String.t(),
          module: module(),
          permissions: [atom()]
        }

  ## Client API

  @doc "Starts the ToolBus GenServer"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Registers a tool module with the registry"
  def register_tool(tool_module) do
    GenServer.call(__MODULE__, {:register_tool, tool_module})
  end

  @doc "Unregisters a tool by name"
  def unregister_tool(tool_name) do
    GenServer.call(__MODULE__, {:unregister_tool, tool_name})
  end

  @doc "Reloads a tool module (for hot-reloading support)"
  def reload_tool(tool_module) do
    GenServer.call(__MODULE__, {:reload_tool, tool_module})
  end

  @doc "Lists all registered tools"
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc "Gets tool information by name"
  def get_tool(tool_name) do
    GenServer.call(__MODULE__, {:get_tool, tool_name})
  end

  @doc "Invokes a tool by name with params and context"
  def invoke_tool(tool_name, params, context) do
    GenServer.call(__MODULE__, {:invoke_tool, tool_name, params, context})
  end

  ## Server Implementation

  @impl true
  def init(:ok) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register_tool, tool_module}, _from, state) do
    case validate_tool_module(tool_module) do
      {:ok, tool_info} ->
        if Map.has_key?(state.tools, tool_info.name) do
          {:reply, {:error, :already_registered}, state}
        else
          new_tools = Map.put(state.tools, tool_info.name, tool_info)
          Logger.info("Registered tool: #{tool_info.name} (#{tool_module})")
          {:reply, :ok, %{state | tools: new_tools}}
        end

      {:error, reason} ->
        Logger.error("Failed to register tool #{tool_module}: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unregister_tool, tool_name}, _from, state) do
    new_tools = Map.delete(state.tools, tool_name)
    Logger.info("Unregistered tool: #{tool_name}")
    {:reply, :ok, %{state | tools: new_tools}}
  end

  @impl true
  def handle_call({:reload_tool, tool_module}, _from, state) do
    case validate_tool_module(tool_module) do
      {:ok, tool_info} ->
        new_tools = Map.put(state.tools, tool_info.name, tool_info)
        Logger.info("Reloaded tool: #{tool_info.name} (#{tool_module})")
        {:reply, :ok, %{state | tools: new_tools}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools_list = Map.values(state.tools)
    {:reply, tools_list, state}
  end

  @impl true
  def handle_call({:get_tool, tool_name}, _from, state) do
    case Map.get(state.tools, tool_name) do
      nil -> {:reply, {:error, :not_found}, state}
      tool_info -> {:reply, {:ok, tool_info}, state}
    end
  end

  @impl true
  def handle_call({:invoke_tool, tool_name, params, context}, _from, state) do
    case Map.get(state.tools, tool_name) do
      nil ->
        {:reply, {:error, :tool_not_found}, state}

      tool_info ->
        case check_permissions(tool_info, context) do
          :ok ->
            result = execute_tool(tool_info, params, context)
            {:reply, result, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  ## Private Functions

  defp validate_tool_module(module) do
    try do
      # Check if module exists and implements the behaviour
      if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) and
           function_exported?(module, :permissions, 0) and
           function_exported?(module, :call, 2) do
        tool_info = %{
          name: module.name(),
          module: module,
          permissions: module.permissions()
        }

        {:ok, tool_info}
      else
        {:error, :invalid_tool_module}
      end
    rescue
      error ->
        {:error, {:module_error, error}}
    end
  end

  defp check_permissions(tool_info, context) do
    allowed_permissions = get_allowed_permissions(context)
    required_permissions = tool_info.permissions

    if permissions_allowed?(required_permissions, allowed_permissions) do
      :ok
    else
      {:error, :permission_denied}
    end
  end

  defp get_allowed_permissions(%Otto.ToolContext{agent_config: config}) do
    Map.get(config, :allowed_permissions, [])
  end

  defp permissions_allowed?(required, allowed) do
    Enum.all?(required, &(&1 in allowed))
  end

  defp execute_tool(tool_info, params, context) do
    try do
      tool_info.module.call(params, context)
    rescue
      error ->
        Logger.error("Tool execution failed for #{tool_info.name}: #{inspect(error)}")
        {:error, {:execution_error, error}}
    catch
      :exit, reason ->
        Logger.error("Tool exited for #{tool_info.name}: #{inspect(reason)}")
        {:error, {:exit, reason}}
    end
  end
end