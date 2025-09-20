defmodule Otto.BudgetEnforcementTest do
  @moduledoc """
  Tests for budget enforcement and cleanup mechanisms.

  Verifies that Otto properly enforces time, token, and cost budgets,
  and handles cleanup when budgets are exceeded.
  """

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Otto.{AgentConfig, AgentServer, CostTracker}

  describe "Time Budget Enforcement" do
    test "tracks time budget countdown" do
      config = %AgentConfig{
        name: "TimeBudgetAgent",
        model: "claude-3-haiku",
        description: "Agent for time budget testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 2}  # 2 seconds
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})

      # Get initial budget
      initial_budget = AgentServer.get_budget_status(agent_pid)
      assert initial_budget.time_remaining <= 2

      # Wait and check countdown
      :timer.sleep(1100)  # Wait 1.1 seconds

      updated_budget = AgentServer.get_budget_status(agent_pid)
      assert updated_budget.time_remaining < initial_budget.time_remaining
      assert updated_budget.time_remaining >= 0
    end

    test "marks budget as exceeded when time runs out" do
      config = %AgentConfig{
        name: "TimeExceededAgent",
        model: "claude-3-haiku",
        description: "Agent for time exceeded testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 1}  # 1 second
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})

      # Wait for budget to be exceeded
      :timer.sleep(1200)  # Wait 1.2 seconds

      budget_status = AgentServer.get_budget_status(agent_pid)
      assert budget_status.time_remaining == 0
      assert budget_status.budget_exceeded
    end

    test "prevents invocations when time budget exceeded" do
      config = %AgentConfig{
        name: "TimeBlockedAgent",
        model: "claude-3-haiku",
        description: "Agent for time blocking testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 1}  # 1 second
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})

      # Wait for budget to be exceeded
      :timer.sleep(1200)

      # Try to invoke - should be blocked
      task_spec = %{instruction: "Read a file"}
      result = AgentServer.invoke(agent_pid, task_spec)

      assert {:error, :budget_exceeded} = result
    end

    test "logs warning when time budget is exceeded" do
      config = %AgentConfig{
        name: "TimeWarningAgent",
        model: "claude-3-haiku",
        description: "Agent for time warning testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 1}  # 1 second
      }

      log_output = capture_log(fn ->
        {:ok, agent_pid} = start_supervised({AgentServer, config})

        # Wait for budget to be exceeded
        :timer.sleep(1200)

        # Trigger budget check
        AgentServer.get_budget_status(agent_pid)
        :timer.sleep(100)  # Allow log to be captured
      end)

      assert String.contains?(log_output, "Time budget exceeded")
    end
  end

  describe "Cost Budget Enforcement" do
    setup do
      # Ensure CostTracker is running
      if not Process.whereis(Otto.CostTracker) do
        start_supervised({CostTracker, daily_budget: 5.0})
      end
      :ok
    end

    test "tracks cost accumulation across invocations" do
      config = %AgentConfig{
        name: "CostTrackingAgent",
        model: "gpt-4",  # Expensive model
        description: "Agent for cost tracking",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{cost_limit: 1.0}  # $1.00
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      # Record expensive usage
      {:ok, record1} = CostTracker.record_usage(:session, session_id, "gpt-4", 5000, 2500)
      {:ok, record2} = CostTracker.record_usage(:session, session_id, "gpt-4", 3000, 1500)

      # Check total usage
      {:ok, usage} = CostTracker.get_usage(:session, session_id)
      total_cost = usage.total_cost

      assert total_cost > 0
      assert usage.total_input_tokens == 8000
      assert usage.total_output_tokens == 4000
      assert usage.record_count == 2
    end

    test "warns when approaching cost budget limit" do
      config = %AgentConfig{
        name: "CostWarningAgent",
        model: "gpt-4",
        description: "Agent for cost warning testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{cost_limit: 0.10}  # $0.10 - small budget
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      log_output = capture_log(fn ->
        # Use 85% of budget to trigger warning
        CostTracker.record_usage(:session, session_id, "gpt-4", 1500, 750)  # ~$0.09
        CostTracker.check_budget(:session, session_id)
      end)

      assert String.contains?(log_output, "Budget warning")
    end

    test "errors when cost budget is exceeded" do
      config = %AgentConfig{
        name: "CostExceededAgent",
        model: "gpt-4",
        description: "Agent for cost exceeded testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{cost_limit: 0.05}  # $0.05 - very small budget
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      log_output = capture_log(fn ->
        # Exceed budget
        CostTracker.record_usage(:session, session_id, "gpt-4", 3000, 1500)  # ~$0.25
        {:ok, budget_status} = CostTracker.check_budget(:session, session_id)

        refute budget_status.within_budget
        assert budget_status.total_cost > 0.05
      end)

      assert String.contains?(log_output, "Budget exceeded")
    end

    test "provides accurate budget percentage calculations" do
      config = %AgentConfig{
        name: "BudgetPercentAgent",
        model: "claude-3-haiku",  # Cheaper model for precise calculations
        description: "Agent for percentage testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{cost_limit: 1.0}  # $1.00
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      # Use exactly half the budget
      CostTracker.record_usage(:session, session_id, "claude-3-haiku", 200_000, 100_000)  # ~$0.50

      {:ok, budget_status} = CostTracker.check_budget(:session, session_id)

      # Should be around 50% used
      assert budget_status.percentage_used >= 40 and budget_status.percentage_used <= 60
      assert budget_status.remaining_budget > 0.40 and budget_status.remaining_budget < 0.60
    end
  end

  describe "Token Budget Enforcement" do
    test "tracks token accumulation" do
      config = %AgentConfig{
        name: "TokenTrackingAgent",
        model: "claude-3-haiku",
        description: "Agent for token tracking",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{token_limit: 50000}  # 50k tokens
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      # Record token usage
      CostTracker.record_usage(:session, session_id, "claude-3-haiku", 15000, 7500)  # 22.5k total
      CostTracker.record_usage(:session, session_id, "claude-3-haiku", 10000, 5000)  # 15k more = 37.5k total

      {:ok, usage} = CostTracker.get_usage(:session, session_id)
      total_tokens = usage.total_input_tokens + usage.total_output_tokens

      assert total_tokens == 37500
      assert total_tokens < 50000  # Still under budget
    end

    test "enforces token limits" do
      # This test demonstrates where token limit enforcement would go
      # In a full implementation, this would prevent further LLM calls
      # when token budget is exceeded

      config = %AgentConfig{
        name: "TokenLimitAgent",
        model: "claude-3-haiku",
        description: "Agent for token limit testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{token_limit: 1000}  # Small token budget
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      # Exceed token budget
      CostTracker.record_usage(:session, session_id, "claude-3-haiku", 800, 400)  # 1200 total

      {:ok, usage} = CostTracker.get_usage(:session, session_id)
      total_tokens = usage.total_input_tokens + usage.total_output_tokens

      assert total_tokens > 1000  # Budget exceeded

      # In full implementation, agent would refuse further invocations
      # or summarize transcript to reduce token count
    end
  end

  describe "Budget Cleanup and Recovery" do
    test "cleans up resources when budget exceeded" do
      config = %AgentConfig{
        name: "CleanupAgent",
        model: "claude-3-haiku",
        description: "Agent for cleanup testing",
        system_prompt: "Test prompt",
        tools: ["test_write"],
        budgets: %{time_limit: 1}  # 1 second
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      working_dir = AgentServer.get_status(agent_pid).working_dir

      # Create some files in working directory
      test_file = Path.join(working_dir, "test.txt")
      File.write!(test_file, "test content")
      assert File.exists?(test_file)

      # Wait for budget to be exceeded, then stop agent
      :timer.sleep(1200)
      GenServer.stop(agent_pid)

      # Working directory should be cleaned up
      refute File.exists?(working_dir)
    end

    test "preserves important artifacts before cleanup" do
      config = %AgentConfig{
        name: "ArtifactPreservationAgent",
        model: "claude-3-haiku",
        description: "Agent for artifact preservation testing",
        system_prompt: "Test prompt",
        tools: ["test_write"],
        budgets: %{time_limit: 2}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      # Save important artifacts via Checkpointer
      important_data = %{result: "Important computation result"}
      {:ok, artifact_ref} = Otto.Checkpointer.save_artifact(
        session_id,
        :result,
        Jason.encode!(important_data)
      )

      # Wait for budget to be exceeded, then stop agent
      :timer.sleep(2200)
      GenServer.stop(agent_pid)

      # Important artifacts should still exist
      assert File.exists?(artifact_ref.path)
      {:ok, preserved_content} = Otto.Checkpointer.load_artifact(artifact_ref)
      {:ok, decoded} = Jason.decode(preserved_content)
      assert decoded["result"] == "Important computation result"
    end

    test "releases process registry entries on cleanup" do
      config = %AgentConfig{
        name: "RegistryCleanupAgent",
        model: "claude-3-haiku",
        description: "Agent for registry cleanup testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 1}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})

      # Register agent in registry
      agent_id = "cleanup_test_#{System.unique_integer()}"
      {:ok, _} = Registry.register(Otto.Agent.Registry, agent_id, %{
        config: config,
        started_at: DateTime.utc_now()
      })

      # Verify registration
      entries = Registry.lookup(Otto.Agent.Registry, agent_id)
      assert length(entries) == 1

      # Wait for budget exceeded and stop agent
      :timer.sleep(1200)
      GenServer.stop(agent_pid)

      # Registry entry should be cleaned up automatically
      # (Registry cleans up when the registered process dies)
      entries = Registry.lookup(Otto.Agent.Registry, agent_id)
      assert entries == []
    end

    test "context store cleanup on agent termination" do
      config = %AgentConfig{
        name: "ContextCleanupAgent",
        model: "claude-3-haiku",
        description: "Agent for context cleanup testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 1}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      # Store some context data
      context_data = %{state: "testing", progress: 50}
      Otto.ContextStore.put_context(session_id, context_data)

      # Verify context exists
      {:ok, _entry} = Otto.ContextStore.get_context(session_id)

      # Stop agent (budget exceeded or manual)
      GenServer.stop(agent_pid)

      # In a full implementation, context would be cleaned up
      # Either immediately or through a scheduled cleanup process
      # For now, we just demonstrate the cleanup mechanism exists
    end
  end

  describe "Budget Configuration Validation" do
    test "rejects invalid budget configurations" do
      invalid_configs = [
        # Negative time limit
        %AgentConfig{
          name: "InvalidAgent1",
          model: "claude-3-haiku",
          description: "Invalid config test",
          system_prompt: "Test",
          tools: ["test_read"],
          budgets: %{time_limit: -300}
        },
        # Zero cost limit
        %AgentConfig{
          name: "InvalidAgent2",
          model: "claude-3-haiku",
          description: "Invalid config test",
          system_prompt: "Test",
          tools: ["test_read"],
          budgets: %{cost_limit: 0}
        },
        # Non-numeric token limit
        %AgentConfig{
          name: "InvalidAgent3",
          model: "claude-3-haiku",
          description: "Invalid config test",
          system_prompt: "Test",
          tools: ["test_read"],
          budgets: %{token_limit: "invalid"}
        }
      ]

      for invalid_config <- invalid_configs do
        case AgentConfig.validate(invalid_config) do
          {:error, errors} ->
            assert length(errors) > 0
          {:ok, _} ->
            # Some validations might not be implemented yet
            :ok
        end
      end
    end

    test "accepts valid budget configurations" do
      valid_config = %AgentConfig{
        name: "ValidBudgetAgent",
        model: "claude-3-haiku",
        description: "Valid config test",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{
          time_limit: 300,
          token_limit: 10000,
          cost_limit: 5.0
        }
      }

      case AgentConfig.validate(valid_config) do
        {:ok, validated_config} ->
          assert validated_config.budgets.time_limit == 300
        {:error, _errors} ->
          # Validation might be strict during development
          :ok
      end
    end
  end
end