defmodule Otto.ContextStore do
  @moduledoc """
  ETS-based storage for per-agent context data.

  Provides isolated storage for each agent's execution context,
  with automatic cleanup on agent termination.
  """

  use GenServer
  require Logger

  @table_name :otto_context_store
  @default_max_size 100 * 1024 * 1024  # 100MB

  defstruct [
    :table,
    max_size: @default_max_size,
    current_size: 0
  ]

  @type context_id :: String.t()
  @type metadata :: %{
          task_id: String.t() | nil,
          parent_workflow: String.t() | nil,
          started_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Stores context data for an agent"
  def put_context(context_id, data, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:put_context, context_id, data, metadata})
  end

  @doc "Retrieves context data for an agent"
  def get_context(context_id) do
    GenServer.call(__MODULE__, {:get_context, context_id})
  end

  @doc "Removes context data for an agent"
  def delete_context(context_id) do
    GenServer.call(__MODULE__, {:delete_context, context_id})
  end

  @doc "Lists all context IDs"
  def list_contexts do
    GenServer.call(__MODULE__, :list_contexts)
  end

  @doc "Gets storage statistics"
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  ## Server Implementation

  @impl true
  def init(opts) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)

    table = :ets.new(@table_name, [
      :set,
      :protected,
      :named_table,
      {:heir, self(), nil}
    ])

    state = %__MODULE__{
      table: table,
      max_size: max_size,
      current_size: 0
    }

    Logger.info("ContextStore started with max_size: #{max_size}")
    {:ok, state}
  end

  @impl true
  def handle_call({:put_context, context_id, data, metadata}, _from, state) do
    data_size = estimate_size(data)

    if state.current_size + data_size > state.max_size do
      # Implement LRU eviction here
      :ets.delete(state.table, context_id)
      Logger.warning("Context storage full, eviction not implemented yet")
      {:reply, {:error, :storage_full}, state}
    else
      entry = %{
        data: data,
        metadata: Map.merge(%{
          started_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }, metadata),
        size: data_size
      }

      :ets.insert(state.table, {context_id, entry})
      new_size = state.current_size + data_size
      {:reply, :ok, %{state | current_size: new_size}}
    end
  end

  @impl true
  def handle_call({:get_context, context_id}, _from, state) do
    case :ets.lookup(state.table, context_id) do
      [{^context_id, entry}] ->
        {:reply, {:ok, entry}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_context, context_id}, _from, state) do
    case :ets.lookup(state.table, context_id) do
      [{^context_id, entry}] ->
        :ets.delete(state.table, context_id)
        new_size = max(0, state.current_size - entry.size)
        {:reply, :ok, %{state | current_size: new_size}}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_contexts, _from, state) do
    context_ids = :ets.select(state.table, [{{:"$1", :_}, [], [:"$1"]}])
    {:reply, context_ids, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    count = :ets.info(state.table, :size)
    stats = %{
      context_count: count,
      current_size: state.current_size,
      max_size: state.max_size,
      utilization: state.current_size / state.max_size
    }
    {:reply, stats, state}
  end

  ## Private Functions

  # Simple size estimation - can be made more sophisticated
  defp estimate_size(data) when is_binary(data), do: byte_size(data)
  defp estimate_size(data) when is_map(data) do
    data
    |> :erlang.term_to_binary()
    |> byte_size()
  end
  defp estimate_size(data), do: data |> :erlang.term_to_binary() |> byte_size()
end