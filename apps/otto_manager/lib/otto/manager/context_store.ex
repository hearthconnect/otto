defmodule Otto.Manager.ContextStore do
  @moduledoc """
  GenServer for managing ephemeral context storage using ETS.

  The Context Store provides fast, in-memory storage for agent contexts, session data,
  and temporary state. It uses ETS tables for high-performance lookups and supports
  TTL-based expiration and cleanup operations.
  """

  use GenServer
  require Logger

  @type context_key :: String.t()
  @type context_data :: map()
  @type ttl :: non_neg_integer() | :infinity

  defstruct [
    :table,
    :cleanup_timer,
    :name,
    cleanup_interval: 60_000,  # 1 minute
    default_ttl: 3_600_000     # 1 hour
  ]

  ## Client API

  @doc """
  Starts the Context Store GenServer.

  ## Options
  - `:name` - Process name for the GenServer
  - `:cleanup_interval` - How often to run cleanup in milliseconds (default: 60_000)
  - `:default_ttl` - Default TTL for contexts in milliseconds (default: 3_600_000)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stores context data with an optional TTL.

  ## Parameters
  - `store` - GenServer process identifier
  - `key` - Unique context key
  - `data` - Context data (any term)
  - `ttl` - Time to live in milliseconds (optional)
  """
  @spec put(GenServer.server(), context_key(), context_data(), keyword()) :: :ok
  def put(store, key, data, opts \\ []) do
    GenServer.call(store, {:put, key, data, opts})
  end

  @doc """
  Retrieves context data by key.
  """
  @spec get(GenServer.server(), context_key()) :: {:ok, context_data()} | {:error, :not_found}
  def get(store, key) do
    GenServer.call(store, {:get, key})
  end

  @doc """
  Deletes context data by key.
  """
  @spec delete(GenServer.server(), context_key()) :: :ok
  def delete(store, key) do
    GenServer.call(store, {:delete, key})
  end

  @doc """
  Lists all context keys.
  """
  @spec list_keys(GenServer.server()) :: [context_key()]
  def list_keys(store) do
    GenServer.call(store, :list_keys)
  end

  @doc """
  Appends an item to a list field in the context data.

  If the field doesn't exist, it creates a new list with the item.
  If the context doesn't exist, returns an error.
  """
  @spec append_to_list(GenServer.server(), context_key(), atom(), any()) :: :ok | {:error, :not_found}
  def append_to_list(store, key, field, item) do
    GenServer.call(store, {:append_to_list, key, field, item})
  end

  @doc """
  Updates a specific field in the context data using a path.

  ## Parameters
  - `store` - GenServer process identifier
  - `key` - Context key
  - `path` - List of keys representing the path to the field
  - `value` - New value for the field
  """
  @spec update_field(GenServer.server(), context_key(), [atom()], any()) :: :ok | {:error, :not_found}
  def update_field(store, key, path, value) do
    GenServer.call(store, {:update_field, key, path, value})
  end

  @doc """
  Forces cleanup of expired contexts.
  """
  @spec cleanup_expired(GenServer.server()) :: :ok
  def cleanup_expired(store) do
    GenServer.call(store, :cleanup_expired)
  end

  @doc """
  Clears all contexts from the store.
  """
  @spec clear_all(GenServer.server()) :: :ok
  def clear_all(store) do
    GenServer.call(store, :clear_all)
  end

  @doc """
  Gets store statistics.
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(store) do
    GenServer.call(store, :get_stats)
  end

  ## Server Implementation

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    cleanup_interval = Keyword.get(opts, :cleanup_interval, 60_000)
    default_ttl = Keyword.get(opts, :default_ttl, 3_600_000)

    table = :ets.new(:"#{name}_contexts", [
      :set,
      :private,
      {:read_concurrency, true}
    ])

    # Schedule cleanup timer
    cleanup_timer = Process.send_after(self(), :cleanup_expired, cleanup_interval)

    state = %__MODULE__{
      table: table,
      cleanup_timer: cleanup_timer,
      name: name,
      cleanup_interval: cleanup_interval,
      default_ttl: default_ttl
    }

    Logger.debug("Started Otto.Manager.ContextStore with name: #{inspect(name)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, data, opts}, _from, state) do
    ttl = Keyword.get(opts, :ttl, state.default_ttl)
    expires_at = if ttl == :infinity, do: :infinity, else: System.monotonic_time(:millisecond) + ttl

    :ets.insert(state.table, {key, data, expires_at})

    Logger.debug("Stored context: #{key} (expires: #{inspect(expires_at)})")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case :ets.lookup(state.table, key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^key, data, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(state.table, key)
          {:reply, {:error, :not_found}, state}
        else
          {:reply, {:ok, data}, state}
        end
    end
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    Logger.debug("Deleted context: #{key}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_keys, _from, state) do
    now = System.monotonic_time(:millisecond)
    all_records = :ets.tab2list(state.table)

    # Filter out expired keys and extract valid keys
    valid_keys = Enum.reduce(all_records, [], fn {key, _data, expires_at}, acc ->
      case expires_at do
        :infinity -> [key | acc]
        expires_at when expires_at > now -> [key | acc]
        _ ->
          # Clean up expired entry
          :ets.delete(state.table, key)
          acc
      end
    end)

    {:reply, Enum.reverse(valid_keys), state}
  end

  @impl true
  def handle_call({:append_to_list, key, field, item}, _from, state) do
    case :ets.lookup(state.table, key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^key, data, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(state.table, key)
          {:reply, {:error, :not_found}, state}
        else
          current_list = Map.get(data, field, [])
          updated_list = current_list ++ [item]
          updated_data = Map.put(data, field, updated_list)

          :ets.insert(state.table, {key, updated_data, expires_at})
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:update_field, key, path, value}, _from, state) do
    case :ets.lookup(state.table, key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^key, data, expires_at}] ->
        if expired?(expires_at) do
          :ets.delete(state.table, key)
          {:reply, {:error, :not_found}, state}
        else
          updated_data = put_in(data, path, value)
          :ets.insert(state.table, {key, updated_data, expires_at})
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call(:cleanup_expired, _from, state) do
    cleanup_count = cleanup_expired_contexts(state)
    Logger.debug("Cleaned up #{cleanup_count} expired contexts")

    try do
      :telemetry.execute([:otto, :context_store, :cleanup], %{cleaned_contexts: cleanup_count})
    rescue
      UndefinedFunctionError -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(state.table)
    Logger.debug("Cleared all contexts")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    total_contexts = :ets.info(state.table, :size)
    memory_usage = :ets.info(state.table, :memory) * :erlang.system_info(:wordsize)
    table_size = :ets.info(state.table, :size)

    stats = %{
      total_contexts: total_contexts,
      memory_usage: memory_usage,
      table_size: table_size
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    cleanup_count = cleanup_expired_contexts(state)

    if cleanup_count > 0 do
      Logger.debug("Cleaned up #{cleanup_count} expired contexts")
    end

    # Schedule next cleanup
    cleanup_timer = Process.send_after(self(), :cleanup_expired, state.cleanup_interval)

    {:noreply, %{state | cleanup_timer: cleanup_timer}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("Otto.Manager.ContextStore terminating: #{inspect(reason)}")

    # Cancel cleanup timer
    if state.cleanup_timer do
      Process.cancel_timer(state.cleanup_timer)
    end

    # Clean up ETS table
    :ets.delete(state.table)

    :ok
  end

  ## Private Functions

  defp expired?(:infinity), do: false
  defp expired?(expires_at) when is_integer(expires_at) do
    System.monotonic_time(:millisecond) > expires_at
  end

  defp cleanup_expired_contexts(state) do
    now = System.monotonic_time(:millisecond)

    # Find and delete expired contexts using a comprehension instead of match spec
    all_entries = :ets.tab2list(state.table)

    expired_keys = for {key, _value, expires_at} <- all_entries,
                      is_integer(expires_at),
                      expires_at < now,
                      do: key

    Enum.each(expired_keys, fn key ->
      :ets.delete(state.table, key)
    end)

    length(expired_keys)
  end
end