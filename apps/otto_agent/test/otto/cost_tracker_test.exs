defmodule Otto.CostTrackerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Otto.CostTracker

  @test_daily_budget 5.0  # $5 for testing

  setup do
    {:ok, pid} = start_supervised({CostTracker, daily_budget: @test_daily_budget})
    {:ok, cost_tracker: pid}
  end

  describe "CostTracker initialization" do
    test "starts with default model pricing" do
      # Verify some common models are configured
      {:ok, stats} = CostTracker.get_stats()
      assert is_map(stats)
    end

    test "accepts custom daily budget" do
      custom_budget = 15.0
      {:ok, _pid} = start_supervised({CostTracker, daily_budget: custom_budget}, id: :custom_budget_tracker)

      # This would be verified through budget checking if we had access to internal state
      # For now, we verify it starts successfully
      assert Process.alive?(Process.whereis(:custom_budget_tracker))
    end
  end

  describe "usage recording" do
    test "records token usage for an agent" do
      result = CostTracker.record_usage(:agent, "test_agent", "claude-3-haiku", 1000, 500)

      assert {:ok, record} = result
      assert record.scope_type == :agent
      assert record.scope_id == "test_agent"
      assert record.model == "claude-3-haiku"
      assert record.input_tokens == 1000
      assert record.output_tokens == 500
      assert record.cost > 0
      assert %DateTime{} = record.timestamp
    end

    test "calculates costs based on model pricing" do
      # Test with known model pricing
      {:ok, record1} = CostTracker.record_usage(:agent, "agent1", "claude-3-haiku", 1000, 500)
      {:ok, record2} = CostTracker.record_usage(:agent, "agent2", "claude-3-sonnet", 1000, 500)

      # Sonnet should be more expensive than Haiku
      assert record2.cost > record1.cost
    end

    test "handles unknown models with fallback pricing" do
      log_output = capture_log(fn ->
        {:ok, record} = CostTracker.record_usage(:agent, "test_agent", "unknown-model", 1000, 500)
        assert record.cost > 0
      end)

      assert String.contains?(log_output, "Unknown model pricing")
    end

    test "records usage for different scope types" do
      scopes = [
        {:agent, "agent_1"},
        {:workflow, "workflow_1"},
        {:session, "session_1"}
      ]

      for {scope_type, scope_id} <- scopes do
        {:ok, record} = CostTracker.record_usage(scope_type, scope_id, "gpt-3.5-turbo", 100, 50)
        assert record.scope_type == scope_type
        assert record.scope_id == scope_id
      end
    end
  end

  describe "usage retrieval" do
    setup do
      # Set up some test data
      test_data = [
        {:agent, "agent_1", "claude-3-haiku", 1000, 500},
        {:agent, "agent_1", "claude-3-haiku", 500, 250},
        {:agent, "agent_2", "claude-3-sonnet", 800, 400},
        {:workflow, "workflow_1", "gpt-4", 200, 100}
      ]

      for {scope_type, scope_id, model, input_tokens, output_tokens} <- test_data do
        CostTracker.record_usage(scope_type, scope_id, model, input_tokens, output_tokens)
      end

      :ok
    end

    test "retrieves usage for specific agent" do
      {:ok, usage} = CostTracker.get_usage(:agent, "agent_1")

      assert usage.scope_type == :agent
      assert usage.scope_id == "agent_1"
      assert usage.total_input_tokens == 1500  # 1000 + 500
      assert usage.total_output_tokens == 750  # 500 + 250
      assert usage.total_cost > 0
      assert usage.record_count == 2
      assert length(usage.records) == 2
    end

    test "retrieves usage for different time ranges" do
      {:ok, today_usage} = CostTracker.get_usage(:agent, "agent_1", :today)
      {:ok, week_usage} = CostTracker.get_usage(:agent, "agent_1", :week)

      # For current test, both should be the same since records are recent
      assert today_usage.total_input_tokens == week_usage.total_input_tokens
      assert today_usage.record_count == week_usage.record_count
    end

    test "returns empty usage for non-existent scope" do
      {:ok, usage} = CostTracker.get_usage(:agent, "non_existent_agent")

      assert usage.total_input_tokens == 0
      assert usage.total_output_tokens == 0
      assert usage.total_cost == 0
      assert usage.record_count == 0
      assert usage.records == []
    end

    test "supports custom time range" do
      {:ok, usage} = CostTracker.get_usage(:agent, "agent_1", {:days, 3})

      # Should include recent records
      assert usage.record_count >= 0
      assert usage.time_range == {:days, 3}
    end
  end

  describe "budget checking" do
    test "reports within budget for normal usage" do
      CostTracker.record_usage(:agent, "budget_test", "claude-3-haiku", 100, 50)

      {:ok, budget_status} = CostTracker.check_budget(:agent, "budget_test")

      assert budget_status.within_budget
      assert budget_status.daily_budget == @test_daily_budget
      assert budget_status.percentage_used < 100
      assert budget_status.remaining_budget > 0
    end

    test "warns when approaching budget limit" do
      # Record expensive usage to trigger warning (80% threshold)
      expensive_tokens = 1_000_000  # Should cost around $4+ for sonnet

      log_output = capture_log(fn ->
        CostTracker.record_usage(:agent, "warning_test", "claude-3-sonnet", expensive_tokens, expensive_tokens)
        CostTracker.check_budget(:agent, "warning_test")
      end)

      assert String.contains?(log_output, "Budget warning")
    end

    test "errors when budget is exceeded" do
      # Record very expensive usage to exceed budget
      very_expensive_tokens = 2_000_000  # Should exceed $5 budget

      log_output = capture_log(fn ->
        CostTracker.record_usage(:agent, "exceed_test", "gpt-4", very_expensive_tokens, very_expensive_tokens)
        {:ok, budget_status} = CostTracker.check_budget(:agent, "exceed_test")
        refute budget_status.within_budget
      end)

      assert String.contains?(log_output, "Budget exceeded")
    end

    test "calculates budget percentage correctly" do
      # Use known costs to test percentage calculation
      CostTracker.record_usage(:agent, "percentage_test", "claude-3-haiku", 500_000, 250_000)  # ~$0.50

      {:ok, budget_status} = CostTracker.check_budget(:agent, "percentage_test")

      expected_percentage = (budget_status.total_cost / @test_daily_budget) * 100
      assert_in_delta budget_status.percentage_used, expected_percentage, 0.1
    end

    test "handles zero usage gracefully" do
      {:ok, budget_status} = CostTracker.check_budget(:agent, "zero_usage_agent")

      assert budget_status.total_cost == 0
      assert budget_status.percentage_used == 0
      assert budget_status.remaining_budget == @test_daily_budget
      assert budget_status.within_budget
    end
  end

  describe "statistics and aggregation" do
    setup do
      # Create diverse usage data
      usage_data = [
        {:agent, "agent_1", "claude-3-haiku", 1000, 500},
        {:agent, "agent_2", "claude-3-sonnet", 800, 400},
        {:workflow, "workflow_1", "gpt-4", 500, 250},
        {:workflow, "workflow_2", "gpt-3.5-turbo", 300, 150},
        {:session, "session_1", "claude-3-haiku", 200, 100}
      ]

      for {scope_type, scope_id, model, input_tokens, output_tokens} <- usage_data do
        CostTracker.record_usage(scope_type, scope_id, model, input_tokens, output_tokens)
      end

      :ok
    end

    test "provides comprehensive statistics" do
      {:ok, stats} = CostTracker.get_stats()

      assert stats.total_records >= 5
      assert stats.total_cost > 0
      assert stats.total_input_tokens > 0
      assert stats.total_output_tokens > 0
      assert stats.daily_budget == @test_daily_budget

      # Check aggregations
      assert is_map(stats.by_scope)
      assert is_map(stats.by_model)

      # Should have entries for each scope type
      assert Map.has_key?(stats.by_scope, :agent)
      assert Map.has_key?(stats.by_scope, :workflow)
      assert Map.has_key?(stats.by_scope, :session)
    end

    test "aggregates usage by scope type correctly" do
      {:ok, stats} = CostTracker.get_stats()

      agent_stats = stats.by_scope[:agent]
      assert agent_stats.record_count >= 2  # agent_1 and agent_2
      assert agent_stats.total_cost > 0

      workflow_stats = stats.by_scope[:workflow]
      assert workflow_stats.record_count >= 2  # workflow_1 and workflow_2
      assert workflow_stats.total_cost > 0
    end

    test "aggregates usage by model correctly" do
      {:ok, stats} = CostTracker.get_stats()

      # Should have stats for each model used
      models_used = ["claude-3-haiku", "claude-3-sonnet", "gpt-4", "gpt-3.5-turbo"]

      for model <- models_used do
        if Map.has_key?(stats.by_model, model) do
          model_stats = stats.by_model[model]
          assert model_stats.record_count > 0
          assert model_stats.total_cost > 0
          assert model_stats.total_input_tokens > 0
          assert model_stats.total_output_tokens > 0
        end
      end
    end

    test "supports different time ranges for statistics" do
      {:ok, today_stats} = CostTracker.get_stats(:today)
      {:ok, week_stats} = CostTracker.get_stats(:week)

      # Week stats should include at least as much as today
      assert week_stats.total_records >= today_stats.total_records
      assert week_stats.total_cost >= today_stats.total_cost
    end
  end

  describe "pricing management" do
    test "updates model pricing" do
      custom_model = "custom-model-v1"
      input_cost = 5.0e-6
      output_cost = 10.0e-6

      assert :ok = CostTracker.update_pricing(custom_model, input_cost, output_cost)

      # Test with usage to verify pricing is applied
      {:ok, record} = CostTracker.record_usage(:agent, "pricing_test", custom_model, 1000, 500)

      expected_cost = (1000 * input_cost) + (500 * output_cost)
      assert_in_delta record.cost, expected_cost, 0.0001
    end

    test "logs pricing updates" do
      log_output = capture_log(fn ->
        CostTracker.update_pricing("test-model", 1.0e-6, 2.0e-6)
      end)

      assert String.contains?(log_output, "Updated pricing for test-model")
    end
  end

  describe "concurrent usage" do
    test "handles concurrent usage recording" do
      agent_id = "concurrent_agent"

      tasks = for i <- 1..10 do
        Task.async(fn ->
          CostTracker.record_usage(:agent, agent_id, "claude-3-haiku", 100 * i, 50 * i)
        end)
      end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      for result <- results do
        assert match?({:ok, _}, result)
      end

      # Verify aggregated usage
      {:ok, usage} = CostTracker.get_usage(:agent, agent_id)
      assert usage.record_count == 10
      assert usage.total_input_tokens == Enum.sum(1..10) * 100  # 100 + 200 + ... + 1000
      assert usage.total_output_tokens == Enum.sum(1..10) * 50   # 50 + 100 + ... + 500
    end

    test "handles concurrent budget checks" do
      agent_id = "budget_concurrent_agent"

      # Record some initial usage
      CostTracker.record_usage(:agent, agent_id, "claude-3-haiku", 1000, 500)

      # Concurrent budget checks
      tasks = for _i <- 1..5 do
        Task.async(fn ->
          CostTracker.check_budget(:agent, agent_id)
        end)
      end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed and return consistent results
      for result <- results do
        assert match?({:ok, _budget_status}, result)
      end

      # All budget statuses should be similar (within small timing variations)
      budget_costs = for {:ok, budget_status} <- results, do: budget_status.total_cost
      cost_range = Enum.max(budget_costs) - Enum.min(budget_costs)
      assert cost_range < 0.01  # Should be very close
    end
  end

  describe "error handling and edge cases" do
    test "handles zero token usage" do
      {:ok, record} = CostTracker.record_usage(:agent, "zero_tokens", "claude-3-haiku", 0, 0)

      assert record.input_tokens == 0
      assert record.output_tokens == 0
      assert record.cost == 0
    end

    test "handles very large token counts" do
      large_count = 10_000_000  # 10M tokens

      {:ok, record} = CostTracker.record_usage(:agent, "large_usage", "gpt-4", large_count, large_count)

      assert record.input_tokens == large_count
      assert record.output_tokens == large_count
      assert record.cost > 100  # Should be expensive
    end

    test "validates scope types" do
      # All valid scope types should work
      valid_scopes = [:agent, :workflow, :session]

      for scope_type <- valid_scopes do
        {:ok, _record} = CostTracker.record_usage(scope_type, "test_id", "claude-3-haiku", 100, 50)
      end
    end
  end
end