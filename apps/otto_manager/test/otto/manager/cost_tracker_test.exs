defmodule Otto.Manager.CostTrackerTest do
  use ExUnit.Case, async: true

  alias Otto.Manager.CostTracker

  setup do
    {:ok, pid} = CostTracker.start_link(name: :"test_cost_tracker_#{:rand.uniform(1000)}")
    {:ok, tracker: pid}
  end

  describe "cost tracking" do
    test "tracks tool usage costs", %{tracker: tracker} do
      usage = %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 150,
        tokens_used: 1000,
        api_calls: 1
      }

      assert :ok = CostTracker.record_tool_usage(tracker, usage)

      stats = CostTracker.get_agent_stats(tracker, "agent_123")
      assert stats.total_tool_executions == 1
      assert stats.total_execution_time_ms == 150
      assert stats.total_tokens == 1000
      assert stats.total_api_calls == 1
    end

    test "tracks LLM usage costs", %{tracker: tracker} do
      usage = %{
        agent_id: "agent_123",
        model: "gpt-4",
        prompt_tokens: 800,
        completion_tokens: 200,
        total_tokens: 1000,
        cost_usd: 0.06
      }

      assert :ok = CostTracker.record_llm_usage(tracker, usage)

      stats = CostTracker.get_agent_stats(tracker, "agent_123")
      assert stats.total_llm_requests == 1
      assert stats.total_tokens == 1000
      assert stats.total_cost_usd == 0.06
    end

    test "tracks storage usage", %{tracker: tracker} do
      usage = %{
        agent_id: "agent_123",
        storage_type: :checkpoint,
        bytes_stored: 1024,
        operation: :write
      }

      assert :ok = CostTracker.record_storage_usage(tracker, usage)

      stats = CostTracker.get_agent_stats(tracker, "agent_123")
      assert stats.total_storage_operations == 1
      assert stats.total_storage_bytes == 1024
    end

    test "aggregates multiple usage events", %{tracker: tracker} do
      # Record multiple tool usages
      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 100,
        tokens_used: 500,
        api_calls: 1
      })

      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "grep",
        execution_time_ms: 50,
        tokens_used: 300,
        api_calls: 1
      })

      # Record LLM usage
      :ok = CostTracker.record_llm_usage(tracker, %{
        agent_id: "agent_123",
        model: "gpt-4",
        prompt_tokens: 800,
        completion_tokens: 200,
        total_tokens: 1000,
        cost_usd: 0.06
      })

      stats = CostTracker.get_agent_stats(tracker, "agent_123")
      assert stats.total_tool_executions == 2
      assert stats.total_execution_time_ms == 150
      assert stats.total_tokens == 1800  # 500 + 300 + 1000
      assert stats.total_api_calls == 2
      assert stats.total_llm_requests == 1
      assert stats.total_cost_usd == 0.06
    end
  end

  describe "cost aggregation by time period" do
    test "gets usage stats for date range", %{tracker: tracker} do
      today = Date.utc_today()
      yesterday = Date.add(today, -1)

      # Record usage for yesterday (simulate by setting timestamp)
      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 100,
        tokens_used: 500,
        api_calls: 1,
        timestamp: DateTime.new!(yesterday, ~T[10:00:00], "Etc/UTC")
      })

      # Record usage for today
      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "grep",
        execution_time_ms: 50,
        tokens_used: 300,
        api_calls: 1,
        timestamp: DateTime.new!(today, ~T[10:00:00], "Etc/UTC")
      })

      # Get stats for today only
      today_stats = CostTracker.get_usage_for_period(tracker, "agent_123", today, today)
      assert today_stats.total_tool_executions == 1
      assert today_stats.total_tokens == 300

      # Get stats for both days
      period_stats = CostTracker.get_usage_for_period(tracker, "agent_123", yesterday, today)
      assert period_stats.total_tool_executions == 2
      assert period_stats.total_tokens == 800
    end

    test "gets daily usage breakdown", %{tracker: tracker} do
      today = Date.utc_today()

      # Record multiple usages today
      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 100,
        tokens_used: 500,
        api_calls: 1
      })

      :ok = CostTracker.record_llm_usage(tracker, %{
        agent_id: "agent_123",
        model: "gpt-4",
        total_tokens: 1000,
        cost_usd: 0.06
      })

      daily_breakdown = CostTracker.get_daily_breakdown(tracker, "agent_123", 7)

      # Should have entry for today
      today_entry = Enum.find(daily_breakdown, fn entry -> entry.date == today end)
      assert today_entry != nil
      assert today_entry.tool_executions == 1
      assert today_entry.llm_requests == 1
      assert today_entry.total_cost_usd == 0.06
    end
  end

  describe "global statistics" do
    test "gets system-wide usage stats", %{tracker: tracker} do
      # Record usage for multiple agents
      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 100,
        tokens_used: 500,
        api_calls: 1
      })

      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_456",
        tool_name: "grep",
        execution_time_ms: 50,
        tokens_used: 300,
        api_calls: 1
      })

      global_stats = CostTracker.get_global_stats(tracker)
      assert global_stats.total_agents == 2
      assert global_stats.total_tool_executions == 2
      assert global_stats.total_tokens == 800
      assert global_stats.total_api_calls == 2
    end

    test "gets top agents by usage", %{tracker: tracker} do
      # Record different amounts of usage for different agents
      :ok = CostTracker.record_llm_usage(tracker, %{
        agent_id: "agent_123",
        model: "gpt-4",
        total_tokens: 1000,
        cost_usd: 0.06
      })

      :ok = CostTracker.record_llm_usage(tracker, %{
        agent_id: "agent_456",
        model: "gpt-4",
        total_tokens: 2000,
        cost_usd: 0.12
      })

      top_agents = CostTracker.get_top_agents_by_cost(tracker, 5)
      assert length(top_agents) == 2

      # Should be sorted by cost (highest first)
      [first, second] = top_agents
      assert first.agent_id == "agent_456"
      assert first.total_cost_usd == 0.12
      assert second.agent_id == "agent_123"
      assert second.total_cost_usd == 0.06
    end

    test "gets tool usage breakdown", %{tracker: tracker} do
      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 100,
        tokens_used: 500,
        api_calls: 2
      })

      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_456",
        tool_name: "file_read",
        execution_time_ms: 150,
        tokens_used: 700,
        api_calls: 1
      })

      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "grep",
        execution_time_ms: 50,
        tokens_used: 200,
        api_calls: 1
      })

      tool_stats = CostTracker.get_tool_usage_breakdown(tracker)

      # Should have stats for both tools
      file_read_stats = Enum.find(tool_stats, fn stat -> stat.tool_name == "file_read" end)
      grep_stats = Enum.find(tool_stats, fn stat -> stat.tool_name == "grep" end)

      assert file_read_stats.execution_count == 2
      assert file_read_stats.total_tokens == 1200
      assert file_read_stats.total_api_calls == 3

      assert grep_stats.execution_count == 1
      assert grep_stats.total_tokens == 200
      assert grep_stats.total_api_calls == 1
    end
  end

  describe "data management" do
    test "clears agent data", %{tracker: tracker} do
      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 100,
        tokens_used: 500,
        api_calls: 1
      })

      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_456",
        tool_name: "grep",
        execution_time_ms: 50,
        tokens_used: 300,
        api_calls: 1
      })

      assert :ok = CostTracker.clear_agent_data(tracker, "agent_123")

      # agent_123 should be cleared
      stats_123 = CostTracker.get_agent_stats(tracker, "agent_123")
      assert stats_123.total_tool_executions == 0

      # agent_456 should remain
      stats_456 = CostTracker.get_agent_stats(tracker, "agent_456")
      assert stats_456.total_tool_executions == 1
    end

    test "clears old data", %{tracker: tracker} do
      old_date = Date.add(Date.utc_today(), -31)  # 31 days ago

      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "file_read",
        execution_time_ms: 100,
        tokens_used: 500,
        api_calls: 1,
        timestamp: DateTime.new!(old_date, ~T[10:00:00], "Etc/UTC")
      })

      :ok = CostTracker.record_tool_usage(tracker, %{
        agent_id: "agent_123",
        tool_name: "grep",
        execution_time_ms: 50,
        tokens_used: 300,
        api_calls: 1
      })

      {:ok, cleared_count} = CostTracker.clear_old_data(tracker, 30)  # Clear data older than 30 days

      assert cleared_count >= 1

      # Recent data should remain
      stats = CostTracker.get_agent_stats(tracker, "agent_123")
      assert stats.total_tool_executions == 1
      assert stats.total_tokens == 300
    end
  end
end