defmodule Otto.CostTracker do
  @moduledoc """
  Tracks token usage and costs for Otto agent operations.

  Provides budget enforcement, usage aggregation, and cost calculation
  based on model pricing configurations.
  """

  use GenServer
  require Logger

  @table_name :otto_cost_tracker
  @default_daily_budget 10.0  # $10 USD

  defstruct [
    :table,
    daily_budget: @default_daily_budget,
    model_pricing: %{}
  ]

  @type scope :: :agent | :workflow | :session
  @type usage_record :: %{
          scope_type: scope(),
          scope_id: String.t(),
          model: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost: float(),
          timestamp: DateTime.t()
        }

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Records token usage for a scope"
  def record_usage(scope_type, scope_id, model, input_tokens, output_tokens) do
    GenServer.call(__MODULE__, {:record_usage, scope_type, scope_id, model, input_tokens, output_tokens})
  end

  @doc "Gets current usage for a scope and time range"
  def get_usage(scope_type, scope_id, time_range \\ :today) do
    GenServer.call(__MODULE__, {:get_usage, scope_type, scope_id, time_range})
  end

  @doc "Checks if a scope is within budget limits"
  def check_budget(scope_type, scope_id, time_range \\ :today) do
    GenServer.call(__MODULE__, {:check_budget, scope_type, scope_id, time_range})
  end

  @doc "Gets aggregated usage statistics"
  def get_stats(time_range \\ :today) do
    GenServer.call(__MODULE__, {:get_stats, time_range})
  end

  @doc "Updates model pricing configuration"
  def update_pricing(model, input_cost_per_token, output_cost_per_token) do
    GenServer.call(__MODULE__, {:update_pricing, model, input_cost_per_token, output_cost_per_token})
  end

  ## Server Implementation

  @impl true
  def init(opts) do
    daily_budget = Keyword.get(opts, :daily_budget, @default_daily_budget)

    table = :ets.new(@table_name, [
      :bag,  # Allow multiple entries per scope
      :protected,
      :named_table,
      {:heir, self(), nil}
    ])

    # Default pricing for common models (per token)
    model_pricing = %{
      "claude-3-sonnet" => %{input: 3.0e-6, output: 15.0e-6},  # $3/$15 per 1M tokens
      "claude-3-haiku" => %{input: 0.25e-6, output: 1.25e-6},  # $0.25/$1.25 per 1M tokens
      "gpt-4" => %{input: 30.0e-6, output: 60.0e-6},           # $30/$60 per 1M tokens
      "gpt-3.5-turbo" => %{input: 0.5e-6, output: 1.5e-6}     # $0.50/$1.50 per 1M tokens
    }

    state = %__MODULE__{
      table: table,
      daily_budget: daily_budget,
      model_pricing: model_pricing
    }

    Logger.info("CostTracker started with daily_budget: $#{daily_budget}")
    {:ok, state}
  end

  @impl true
  def handle_call({:record_usage, scope_type, scope_id, model, input_tokens, output_tokens}, _from, state) do
    cost = calculate_cost(state, model, input_tokens, output_tokens)

    record = %{
      scope_type: scope_type,
      scope_id: scope_id,
      model: model,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost: cost,
      timestamp: DateTime.utc_now()
    }

    key = {scope_type, scope_id, DateTime.to_date(record.timestamp)}
    :ets.insert(state.table, {key, record})

    Logger.debug("Recorded usage for #{scope_type}:#{scope_id} - $#{Float.round(cost, 4)}")
    {:reply, {:ok, record}, state}
  end

  @impl true
  def handle_call({:get_usage, scope_type, scope_id, time_range}, _from, state) do
    usage = do_get_usage(state, scope_type, scope_id, time_range)
    {:reply, {:ok, usage}, state}
  end

  @impl true
  def handle_call({:check_budget, scope_type, scope_id, time_range}, _from, state) do
    usage = do_get_usage(state, scope_type, scope_id, time_range)
    total_cost = usage.total_cost

    budget_status = %{
      total_cost: total_cost,
      daily_budget: state.daily_budget,
      remaining_budget: max(0, state.daily_budget - total_cost),
      percentage_used: min(100, (total_cost / state.daily_budget) * 100),
      within_budget: total_cost <= state.daily_budget
    }

    # Emit warnings
    if budget_status.percentage_used >= 80 and budget_status.percentage_used < 100 do
      Logger.warning("Budget warning: #{scope_type}:#{scope_id} at #{Float.round(budget_status.percentage_used, 1)}% of daily budget")
    end

    if not budget_status.within_budget do
      Logger.error("Budget exceeded: #{scope_type}:#{scope_id} spent $#{Float.round(total_cost, 2)} vs budget $#{state.daily_budget}")
    end

    {:reply, {:ok, budget_status}, state}
  end

  @impl true
  def handle_call({:get_stats, time_range}, _from, state) do
    stats = do_get_stats(state, time_range)
    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_call({:update_pricing, model, input_cost, output_cost}, _from, state) do
    new_pricing = Map.put(state.model_pricing, model, %{input: input_cost, output: output_cost})
    new_state = %{state | model_pricing: new_pricing}

    Logger.info("Updated pricing for #{model}: input=$#{input_cost}/token, output=$#{output_cost}/token")
    {:reply, :ok, new_state}
  end

  ## Private Functions

  defp calculate_cost(state, model, input_tokens, output_tokens) do
    case Map.get(state.model_pricing, model) do
      %{input: input_cost, output: output_cost} ->
        (input_tokens * input_cost) + (output_tokens * output_cost)
      nil ->
        Logger.warning("Unknown model pricing: #{model}, using default")
        # Default fallback pricing
        (input_tokens * 1.0e-6) + (output_tokens * 2.0e-6)
    end
  end

  defp do_get_usage(state, scope_type, scope_id, time_range) do
    date_range = get_date_range(time_range)

    # Find all matching records
    pattern = case scope_type do
      :all -> {:_, :_}
      _ -> {{scope_type, scope_id, :_}, :_}
    end

    records = :ets.match_object(state.table, pattern)
              |> Enum.filter(fn {_key, record} ->
                date = DateTime.to_date(record.timestamp)
                date in date_range
              end)
              |> Enum.map(fn {_key, record} -> record end)

    # Aggregate usage
    total_input_tokens = Enum.sum(Enum.map(records, & &1.input_tokens))
    total_output_tokens = Enum.sum(Enum.map(records, & &1.output_tokens))
    total_cost = Enum.sum(Enum.map(records, & &1.cost))

    %{
      scope_type: scope_type,
      scope_id: scope_id,
      time_range: time_range,
      total_input_tokens: total_input_tokens,
      total_output_tokens: total_output_tokens,
      total_cost: total_cost,
      record_count: length(records),
      records: records
    }
  end

  defp do_get_stats(state, time_range) do
    date_range = get_date_range(time_range)

    all_records = :ets.tab2list(state.table)
                  |> Enum.filter(fn {_key, record} ->
                    date = DateTime.to_date(record.timestamp)
                    date in date_range
                  end)
                  |> Enum.map(fn {_key, record} -> record end)

    # Group by scope type and model
    by_scope = Enum.group_by(all_records, & &1.scope_type)
    by_model = Enum.group_by(all_records, & &1.model)

    %{
      time_range: time_range,
      total_records: length(all_records),
      total_cost: Enum.sum(Enum.map(all_records, & &1.cost)),
      total_input_tokens: Enum.sum(Enum.map(all_records, & &1.input_tokens)),
      total_output_tokens: Enum.sum(Enum.map(all_records, & &1.output_tokens)),
      by_scope: summarize_groups(by_scope),
      by_model: summarize_groups(by_model),
      daily_budget: state.daily_budget
    }
  end

  defp summarize_groups(groups) do
    for {key, records} <- groups, into: %{} do
      {key, %{
        record_count: length(records),
        total_cost: Enum.sum(Enum.map(records, & &1.cost)),
        total_input_tokens: Enum.sum(Enum.map(records, & &1.input_tokens)),
        total_output_tokens: Enum.sum(Enum.map(records, & &1.output_tokens))
      }}
    end
  end

  defp get_date_range(:today) do
    today = Date.utc_today()
    [today]
  end

  defp get_date_range(:week) do
    today = Date.utc_today()
    start_of_week = Date.add(today, -6)
    Date.range(start_of_week, today) |> Enum.to_list()
  end

  defp get_date_range(:month) do
    today = Date.utc_today()
    start_of_month = Date.add(today, -29)
    Date.range(start_of_month, today) |> Enum.to_list()
  end

  defp get_date_range({:days, n}) do
    today = Date.utc_today()
    start_date = Date.add(today, -(n - 1))
    Date.range(start_date, today) |> Enum.to_list()
  end
end