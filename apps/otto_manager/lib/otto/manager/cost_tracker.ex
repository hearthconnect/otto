defmodule Otto.Manager.CostTracker do
  @moduledoc """
  GenServer for tracking and aggregating usage costs across the Otto system.

  The Cost Tracker monitors resource usage including tool executions, LLM API calls,
  storage operations, and other billable activities. It provides detailed analytics
  and cost breakdowns for agents, tools, and time periods.
  """

  use GenServer
  require Logger

  @type agent_id :: String.t()
  @type tool_name :: String.t()
  @type usage_record :: map()

  defstruct [
    :table,
    :name,
    cleanup_interval: 86_400_000  # 24 hours
  ]

  ## Client API

  @doc """
  Starts the Cost Tracker GenServer.

  ## Options
  - `:name` - Process name for the GenServer
  - `:cleanup_interval` - How often to run cleanup in milliseconds
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records tool usage for cost tracking.

  ## Parameters
  - `tracker` - GenServer process identifier
  - `usage` - Map containing usage details:
    - `:agent_id` - Agent that used the tool
    - `:tool_name` - Name of the tool used
    - `:execution_time_ms` - Time taken to execute
    - `:tokens_used` - Number of tokens consumed (optional)
    - `:api_calls` - Number of API calls made (optional)
    - `:timestamp` - When the usage occurred (defaults to now)
  """
  @spec record_tool_usage(GenServer.server(), map()) :: :ok
  def record_tool_usage(tracker, usage) do
    GenServer.call(tracker, {:record_tool_usage, usage})
  end

  @doc """
  Records LLM usage for cost tracking.

  ## Parameters
  - `tracker` - GenServer process identifier
  - `usage` - Map containing LLM usage details:
    - `:agent_id` - Agent that made the request
    - `:model` - LLM model used
    - `:prompt_tokens` - Input tokens (optional)
    - `:completion_tokens` - Output tokens (optional)
    - `:total_tokens` - Total tokens used
    - `:cost_usd` - Cost in USD (optional)
    - `:timestamp` - When the usage occurred (defaults to now)
  """
  @spec record_llm_usage(GenServer.server(), map()) :: :ok
  def record_llm_usage(tracker, usage) do
    GenServer.call(tracker, {:record_llm_usage, usage})
  end

  @doc """
  Records storage usage for cost tracking.
  """
  @spec record_storage_usage(GenServer.server(), map()) :: :ok
  def record_storage_usage(tracker, usage) do
    GenServer.call(tracker, {:record_storage_usage, usage})
  end

  @doc """
  Gets aggregated usage statistics for a specific agent.
  """
  @spec get_agent_stats(GenServer.server(), agent_id()) :: map()
  def get_agent_stats(tracker, agent_id) do
    GenServer.call(tracker, {:get_agent_stats, agent_id})
  end

  @doc """
  Gets usage statistics for a specific time period.

  ## Parameters
  - `tracker` - GenServer process identifier
  - `agent_id` - Agent ID (optional, nil for all agents)
  - `start_date` - Start of the period
  - `end_date` - End of the period
  """
  @spec get_usage_for_period(GenServer.server(), agent_id() | nil, Date.t(), Date.t()) :: map()
  def get_usage_for_period(tracker, agent_id, start_date, end_date) do
    GenServer.call(tracker, {:get_usage_for_period, agent_id, start_date, end_date})
  end

  @doc """
  Gets daily usage breakdown for the past N days.
  """
  @spec get_daily_breakdown(GenServer.server(), agent_id() | nil, non_neg_integer()) :: [map()]
  def get_daily_breakdown(tracker, agent_id, days_back \\ 30) do
    GenServer.call(tracker, {:get_daily_breakdown, agent_id, days_back})
  end

  @doc """
  Gets system-wide usage statistics.
  """
  @spec get_global_stats(GenServer.server()) :: map()
  def get_global_stats(tracker) do
    GenServer.call(tracker, :get_global_stats)
  end

  @doc """
  Gets top agents by total cost.
  """
  @spec get_top_agents_by_cost(GenServer.server(), non_neg_integer()) :: [map()]
  def get_top_agents_by_cost(tracker, limit \\ 10) do
    GenServer.call(tracker, {:get_top_agents_by_cost, limit})
  end

  @doc """
  Gets usage breakdown by tool.
  """
  @spec get_tool_usage_breakdown(GenServer.server()) :: [map()]
  def get_tool_usage_breakdown(tracker) do
    GenServer.call(tracker, :get_tool_usage_breakdown)
  end

  @doc """
  Clears all usage data for a specific agent.
  """
  @spec clear_agent_data(GenServer.server(), agent_id()) :: :ok
  def clear_agent_data(tracker, agent_id) do
    GenServer.call(tracker, {:clear_agent_data, agent_id})
  end

  @doc """
  Clears usage data older than the specified number of days.
  """
  @spec clear_old_data(GenServer.server(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def clear_old_data(tracker, days_to_keep) do
    GenServer.call(tracker, {:clear_old_data, days_to_keep})
  end

  ## Server Implementation

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    cleanup_interval = Keyword.get(opts, :cleanup_interval, 86_400_000)

    table = :ets.new(:"#{name}_usage", [
      :bag,  # Allow multiple records per key
      :private,
      {:read_concurrency, true}
    ])

    # Schedule periodic cleanup
    Process.send_after(self(), :periodic_cleanup, cleanup_interval)

    state = %__MODULE__{
      table: table,
      name: name,
      cleanup_interval: cleanup_interval
    }

    Logger.debug("Started Otto.Manager.CostTracker with name: #{inspect(name)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:record_tool_usage, usage}, _from, state) do
    record = %{
      type: :tool_usage,
      agent_id: Map.get(usage, :agent_id),
      tool_name: Map.get(usage, :tool_name),
      execution_time_ms: Map.get(usage, :execution_time_ms, 0),
      tokens_used: Map.get(usage, :tokens_used, 0),
      api_calls: Map.get(usage, :api_calls, 0),
      timestamp: Map.get(usage, :timestamp, DateTime.utc_now())
    }

    :ets.insert(state.table, {record.agent_id, record})

    Logger.debug("Recorded tool usage: #{record.agent_id} used #{record.tool_name}")
    try do
      :telemetry.execute([:otto, :cost_tracker, :tool_usage], %{
        execution_time_ms: record.execution_time_ms,
        tokens_used: record.tokens_used,
        api_calls: record.api_calls
      }, %{agent_id: record.agent_id, tool_name: record.tool_name})
    rescue
      UndefinedFunctionError -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_llm_usage, usage}, _from, state) do
    record = %{
      type: :llm_usage,
      agent_id: Map.get(usage, :agent_id),
      model: Map.get(usage, :model),
      prompt_tokens: Map.get(usage, :prompt_tokens, 0),
      completion_tokens: Map.get(usage, :completion_tokens, 0),
      total_tokens: Map.get(usage, :total_tokens, 0),
      cost_usd: Map.get(usage, :cost_usd, 0.0),
      timestamp: Map.get(usage, :timestamp, DateTime.utc_now())
    }

    :ets.insert(state.table, {record.agent_id, record})

    Logger.debug("Recorded LLM usage: #{record.agent_id} used #{record.model} (#{record.total_tokens} tokens)")
    try do
      :telemetry.execute([:otto, :cost_tracker, :llm_usage], %{
        total_tokens: record.total_tokens,
        cost_usd: record.cost_usd
      }, %{agent_id: record.agent_id, model: record.model})
    rescue
      UndefinedFunctionError -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_storage_usage, usage}, _from, state) do
    record = %{
      type: :storage_usage,
      agent_id: Map.get(usage, :agent_id),
      storage_type: Map.get(usage, :storage_type),
      bytes_stored: Map.get(usage, :bytes_stored, 0),
      operation: Map.get(usage, :operation),
      timestamp: Map.get(usage, :timestamp, DateTime.utc_now())
    }

    :ets.insert(state.table, {record.agent_id, record})

    Logger.debug("Recorded storage usage: #{record.agent_id} #{record.operation} #{record.bytes_stored} bytes")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_agent_stats, agent_id}, _from, state) do
    records = :ets.lookup(state.table, agent_id)
    stats = aggregate_agent_records(records)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_usage_for_period, agent_id, start_date, end_date}, _from, state) do
    records = if agent_id do
      :ets.lookup(state.table, agent_id)
    else
      :ets.tab2list(state.table)
    end

    # Filter by date range
    filtered_records = Enum.filter(records, fn {_key, record} ->
      record_date = DateTime.to_date(record.timestamp)
      Date.compare(record_date, start_date) != :lt and Date.compare(record_date, end_date) != :gt
    end)

    stats = aggregate_agent_records(filtered_records)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_daily_breakdown, agent_id, days_back}, _from, state) do
    end_date = Date.utc_today()
    start_date = Date.add(end_date, -days_back + 1)

    records = if agent_id do
      :ets.lookup(state.table, agent_id)
    else
      :ets.tab2list(state.table)
    end

    # Group by date and aggregate
    daily_stats = records
    |> Enum.filter(fn {_key, record} ->
      record_date = DateTime.to_date(record.timestamp)
      Date.compare(record_date, start_date) != :lt and Date.compare(record_date, end_date) != :gt
    end)
    |> Enum.group_by(fn {_key, record} ->
      DateTime.to_date(record.timestamp)
    end)
    |> Enum.map(fn {date, day_records} ->
      day_stats = aggregate_agent_records(day_records)
      Map.put(day_stats, :date, date)
    end)
    |> Enum.sort_by(& &1.date, Date)

    {:reply, daily_stats, state}
  end

  @impl true
  def handle_call(:get_global_stats, _from, state) do
    all_records = :ets.tab2list(state.table)

    # Group by agent and aggregate
    agent_stats = all_records
    |> Enum.group_by(fn {agent_id, _record} -> agent_id end)
    |> Enum.map(fn {agent_id, agent_records} ->
      {agent_id, aggregate_agent_records(agent_records)}
    end)

    # Calculate global totals
    global_stats = %{
      total_agents: length(agent_stats),
      total_tool_executions: Enum.sum(Enum.map(agent_stats, fn {_, stats} -> stats.total_tool_executions end)),
      total_llm_requests: Enum.sum(Enum.map(agent_stats, fn {_, stats} -> stats.total_llm_requests end)),
      total_tokens: Enum.sum(Enum.map(agent_stats, fn {_, stats} -> stats.total_tokens end)),
      total_api_calls: Enum.sum(Enum.map(agent_stats, fn {_, stats} -> stats.total_api_calls end)),
      total_cost_usd: Enum.sum(Enum.map(agent_stats, fn {_, stats} -> stats.total_cost_usd end)),
      total_storage_operations: Enum.sum(Enum.map(agent_stats, fn {_, stats} -> stats.total_storage_operations end)),
      total_storage_bytes: Enum.sum(Enum.map(agent_stats, fn {_, stats} -> stats.total_storage_bytes end))
    }

    {:reply, global_stats, state}
  end

  @impl true
  def handle_call({:get_top_agents_by_cost, limit}, _from, state) do
    all_records = :ets.tab2list(state.table)

    top_agents = all_records
    |> Enum.group_by(fn {agent_id, _record} -> agent_id end)
    |> Enum.map(fn {agent_id, agent_records} ->
      stats = aggregate_agent_records(agent_records)
      Map.put(stats, :agent_id, agent_id)
    end)
    |> Enum.sort_by(& &1.total_cost_usd, :desc)
    |> Enum.take(limit)

    {:reply, top_agents, state}
  end

  @impl true
  def handle_call(:get_tool_usage_breakdown, _from, state) do
    all_records = :ets.tab2list(state.table)

    tool_stats = all_records
    |> Enum.filter(fn {_agent_id, record} -> record.type == :tool_usage end)
    |> Enum.group_by(fn {_agent_id, record} -> record.tool_name end)
    |> Enum.map(fn {tool_name, tool_records} ->
      records_data = Enum.map(tool_records, fn {_agent_id, record} -> record end)

      %{
        tool_name: tool_name,
        execution_count: length(records_data),
        total_execution_time_ms: Enum.sum(Enum.map(records_data, & &1.execution_time_ms)),
        total_tokens: Enum.sum(Enum.map(records_data, & &1.tokens_used)),
        total_api_calls: Enum.sum(Enum.map(records_data, & &1.api_calls)),
        average_execution_time_ms: if(length(records_data) > 0, do: Enum.sum(Enum.map(records_data, & &1.execution_time_ms)) / length(records_data), else: 0)
      }
    end)
    |> Enum.sort_by(& &1.execution_count, :desc)

    {:reply, tool_stats, state}
  end

  @impl true
  def handle_call({:clear_agent_data, agent_id}, _from, state) do
    :ets.delete(state.table, agent_id)
    Logger.debug("Cleared all usage data for agent: #{agent_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_old_data, days_to_keep}, _from, state) do
    cutoff_date = Date.add(Date.utc_today(), -days_to_keep)
    all_records = :ets.tab2list(state.table)

    {to_delete, to_keep} = Enum.split_with(all_records, fn {_agent_id, record} ->
      record_date = DateTime.to_date(record.timestamp)
      Date.compare(record_date, cutoff_date) == :lt
    end)

    # Clear table and re-insert records to keep
    :ets.delete_all_objects(state.table)
    Enum.each(to_keep, fn {agent_id, record} ->
      :ets.insert(state.table, {agent_id, record})
    end)

    deleted_count = length(to_delete)
    Logger.info("Cleared #{deleted_count} old usage records (older than #{days_to_keep} days)")

    {:reply, {:ok, deleted_count}, state}
  end

  @impl true
  def handle_info(:periodic_cleanup, state) do
    # Automatically clean up data older than 90 days
    case :ets.info(state.table, :size) do
      size when size > 10_000 ->
        GenServer.cast(self(), {:cleanup_old_data, 90})
      _ ->
        :ok
    end

    # Schedule next cleanup
    Process.send_after(self(), :periodic_cleanup, state.cleanup_interval)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:cleanup_old_data, days_to_keep}, state) do
    {:ok, deleted_count} = clear_old_data(self(), days_to_keep)
    Logger.debug("Periodic cleanup removed #{deleted_count} old records")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("Otto.Manager.CostTracker terminating: #{inspect(reason)}")

    # Clean up ETS table
    :ets.delete(state.table)

    :ok
  end

  ## Private Functions

  defp aggregate_agent_records(records) do
    records_data = Enum.map(records, fn
      {_agent_id, record} -> record
      record when is_map(record) -> record
    end)

    tool_records = Enum.filter(records_data, & &1.type == :tool_usage)
    llm_records = Enum.filter(records_data, & &1.type == :llm_usage)
    storage_records = Enum.filter(records_data, & &1.type == :storage_usage)

    %{
      total_tool_executions: length(tool_records),
      total_llm_requests: length(llm_records),
      total_execution_time_ms: Enum.sum(Enum.map(tool_records, & &1.execution_time_ms)),
      total_tokens: Enum.sum(Enum.map(tool_records, & &1.tokens_used)) + Enum.sum(Enum.map(llm_records, & &1.total_tokens)),
      total_api_calls: Enum.sum(Enum.map(tool_records, & &1.api_calls)),
      total_cost_usd: Enum.sum(Enum.map(llm_records, & &1.cost_usd)),
      total_storage_operations: length(storage_records),
      total_storage_bytes: Enum.sum(Enum.map(storage_records, & &1.bytes_stored)),
      tool_executions: length(tool_records),
      llm_requests: length(llm_records),
      storage_operations: length(storage_records)
    }
  end
end