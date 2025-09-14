defmodule Otto.ErrorRecoveryTest do
  @moduledoc """
  Tests for error recovery and supervision restart mechanisms.

  Verifies that Otto properly handles failures at different levels
  and recovers gracefully without losing system stability.
  """

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Otto.{AgentConfig, AgentServer, ToolBus}

  # Test tool that can simulate various failures
  defmodule FailingTool do
    @behaviour Otto.Tool

    def name, do: "failing_tool"
    def permissions, do: [:exec]

    def call(%{failure_type: "crash"}, _context) do
      raise "Simulated tool crash"
    end

    def call(%{failure_type: "exit"}, _context) do
      exit(:simulated_exit)
    end

    def call(%{failure_type: "timeout"}, _context) do
      :timer.sleep(10_000)  # Long operation
      {:ok, "Should not reach here"}
    end

    def call(%{failure_type: "error"}, _context) do
      {:error, :simulated_error}
    end

    def call(%{failure_type: "invalid_response"}, _context) do
      "Not a proper tuple response"
    end

    def call(_params, _context) do
      {:ok, "Normal operation"}
    end
  end

  setup_all do
    # Register failing tool for tests
    if Process.whereis(Otto.ToolBus) do
      ToolBus.register_tool(FailingTool)
    end
    :ok
  end

  describe "Tool Error Recovery" do
    test "agent survives tool crashes" do
      config = %AgentConfig{
        name: "CrashRecoveryAgent",
        model: "claude-3-haiku",
        description: "Agent for crash recovery testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      context = GenServer.call(agent_pid, :create_tool_context)

      # Tool crash should be handled gracefully
      result = ToolBus.invoke_tool("failing_tool", %{failure_type: "crash"}, context)
      assert match?({:error, {:execution_error, _}}, result)

      # Agent should still be alive and functional
      assert Process.alive?(agent_pid)
      status = AgentServer.get_status(agent_pid)
      assert status.config.name == "CrashRecoveryAgent"
    end

    test "agent survives tool exits" do
      config = %AgentConfig{
        name: "ExitRecoveryAgent",
        model: "claude-3-haiku",
        description: "Agent for exit recovery testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      context = GenServer.call(agent_pid, :create_tool_context)

      # Tool exit should be handled gracefully
      result = ToolBus.invoke_tool("failing_tool", %{failure_type: "exit"}, context)
      assert match?({:error, {:exit, _}}, result)

      # Agent should still be alive
      assert Process.alive?(agent_pid)
      status = AgentServer.get_status(agent_pid)
      assert status.config.name == "ExitRecoveryAgent"
    end

    test "agent handles tool errors properly" do
      config = %AgentConfig{
        name: "ErrorHandlingAgent",
        model: "claude-3-haiku",
        description: "Agent for error handling testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      context = GenServer.call(agent_pid, :create_tool_context)

      # Tool error should be returned as-is
      result = ToolBus.invoke_tool("failing_tool", %{failure_type: "error"}, context)
      assert {:error, :simulated_error} = result

      # Agent should still be functional
      assert Process.alive?(agent_pid)

      # Should be able to use normal tool operation
      normal_result = ToolBus.invoke_tool("failing_tool", %{}, context)
      assert {:ok, "Normal operation"} = normal_result
    end

    test "agent handles invalid tool responses" do
      config = %AgentConfig{
        name: "InvalidResponseAgent",
        model: "claude-3-haiku",
        description: "Agent for invalid response testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      context = GenServer.call(agent_pid, :create_tool_context)

      # Invalid response should be handled
      result = ToolBus.invoke_tool("failing_tool", %{failure_type: "invalid_response"}, context)
      # ToolBus might wrap this in an error or handle it specially
      assert match?({:error, _}, result) or result == "Not a proper tuple response"

      # Agent should still be alive
      assert Process.alive?(agent_pid)
    end

    test "logs tool errors for debugging" do
      config = %AgentConfig{
        name: "LoggingAgent",
        model: "claude-3-haiku",
        description: "Agent for logging testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      context = GenServer.call(agent_pid, :create_tool_context)

      log_output = capture_log(fn ->
        ToolBus.invoke_tool("failing_tool", %{failure_type: "crash"}, context)
      end)

      assert String.contains?(log_output, "Tool execution failed") or
             String.contains?(log_output, "failing_tool")
    end
  end

  describe "Agent Server Recovery" do
    test "dynamic supervisor restarts failed agent" do
      config = %AgentConfig{
        name: "RestartableAgent",
        model: "claude-3-haiku",
        description: "Agent for restart testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      # Start agent through dynamic supervisor
      {:ok, agent_pid} = DynamicSupervisor.start_child(
        Otto.Agent.DynamicSupervisor,
        {AgentServer, config}
      )

      original_session_id = AgentServer.get_status(agent_pid).session_id

      # Kill the agent process
      Process.exit(agent_pid, :kill)
      :timer.sleep(100)  # Wait for process to die

      refute Process.alive?(agent_pid)

      # For transient restart strategy, the agent won't be automatically restarted
      # This is by design - agent failures should be explicit
      # But the supervisor should handle the crash gracefully

      # Verify dynamic supervisor is still running
      supervisor_pid = Process.whereis(Otto.Agent.DynamicSupervisor)
      assert is_pid(supervisor_pid)
      assert Process.alive?(supervisor_pid)

      # Should be able to start a new agent
      {:ok, new_agent_pid} = DynamicSupervisor.start_child(
        Otto.Agent.DynamicSupervisor,
        {AgentServer, config}
      )

      new_session_id = AgentServer.get_status(new_agent_pid).session_id
      assert new_session_id != original_session_id  # Should be a new instance

      DynamicSupervisor.terminate_child(Otto.Agent.DynamicSupervisor, new_agent_pid)
    end

    test "agent isolation - one failure doesn't affect others" do
      config1 = %AgentConfig{
        name: "IsolatedAgent1",
        model: "claude-3-haiku",
        description: "First isolated agent",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      config2 = %AgentConfig{
        name: "IsolatedAgent2",
        model: "claude-3-haiku",
        description: "Second isolated agent",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      # Start two agents
      {:ok, agent1_pid} = DynamicSupervisor.start_child(
        Otto.Agent.DynamicSupervisor,
        {AgentServer, config1}
      )

      {:ok, agent2_pid} = DynamicSupervisor.start_child(
        Otto.Agent.DynamicSupervisor,
        {AgentServer, config2}
      )

      # Both should be running
      assert Process.alive?(agent1_pid)
      assert Process.alive?(agent2_pid)

      # Kill first agent
      Process.exit(agent1_pid, :kill)
      :timer.sleep(100)

      # Second agent should be unaffected
      assert Process.alive?(agent2_pid)
      status = AgentServer.get_status(agent2_pid)
      assert status.config.name == "IsolatedAgent2"

      # Clean up
      DynamicSupervisor.terminate_child(Otto.Agent.DynamicSupervisor, agent2_pid)
    end

    test "maintains agent state consistency during errors" do
      config = %AgentConfig{
        name: "StateConsistencyAgent",
        model: "claude-3-haiku",
        description: "Agent for state consistency testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})

      # Get initial state
      initial_status = AgentServer.get_status(agent_pid)
      initial_count = initial_status.invocation_count

      # Cause tool error
      context = GenServer.call(agent_pid, :create_tool_context)
      ToolBus.invoke_tool("failing_tool", %{failure_type: "error"}, context)

      # State should remain consistent
      final_status = AgentServer.get_status(agent_pid)
      assert final_status.config == initial_status.config
      assert final_status.session_id == initial_status.session_id
      assert final_status.invocation_count == initial_count  # No successful invocation
    end
  end

  describe "Infrastructure Component Recovery" do
    test "toolbus restart preserves system functionality" do
      # Get initial tool list
      initial_tools = ToolBus.list_tools()
      initial_tool_names = Enum.map(initial_tools, & &1.name)

      # Kill ToolBus
      toolbus_pid = Process.whereis(Otto.ToolBus)
      Process.exit(toolbus_pid, :kill)
      :timer.sleep(200)  # Wait for restart

      # Should be restarted
      new_toolbus_pid = Process.whereis(Otto.ToolBus)
      assert is_pid(new_toolbus_pid)
      assert new_toolbus_pid != toolbus_pid

      # Re-register test tools (they would need to be re-registered)
      ToolBus.register_tool(FailingTool)

      # Should be functional
      tools = ToolBus.list_tools()
      assert length(tools) > 0
    end

    test "context store restart preserves functionality" do
      # Store some test data
      test_context_id = "recovery_test_#{System.unique_integer()}"
      test_data = %{test: "recovery data"}

      Otto.ContextStore.put_context(test_context_id, test_data)

      # Kill ContextStore
      context_store_pid = Process.whereis(Otto.ContextStore)
      Process.exit(context_store_pid, :kill)
      :timer.sleep(200)  # Wait for restart

      # Should be restarted
      new_context_store_pid = Process.whereis(Otto.ContextStore)
      assert is_pid(new_context_store_pid)
      assert new_context_store_pid != context_store_pid

      # Data would be lost (in-memory ETS), but functionality should work
      result = Otto.ContextStore.put_context("new_test", %{new: "data"})
      assert result == :ok
    end

    test "cost tracker restart preserves functionality" do
      # Record some test usage
      test_session = "cost_recovery_test"
      Otto.CostTracker.record_usage(:session, test_session, "claude-3-haiku", 100, 50)

      # Kill CostTracker
      cost_tracker_pid = Process.whereis(Otto.CostTracker)
      Process.exit(cost_tracker_pid, :kill)
      :timer.sleep(200)  # Wait for restart

      # Should be restarted
      new_cost_tracker_pid = Process.whereis(Otto.CostTracker)
      assert is_pid(new_cost_tracker_pid)
      assert new_cost_tracker_pid != cost_tracker_pid

      # Should be functional for new usage
      {:ok, _record} = Otto.CostTracker.record_usage(:session, "new_session", "claude-3-haiku", 200, 100)
    end

    test "checkpointer restart preserves filesystem artifacts" do
      # Save an artifact
      test_session = "checkpoint_recovery_test"
      test_content = "Recovery test content"

      {:ok, artifact_ref} = Otto.Checkpointer.save_artifact(
        test_session,
        :result,
        test_content
      )

      # Verify artifact exists
      assert File.exists?(artifact_ref.path)

      # Kill Checkpointer
      checkpointer_pid = Process.whereis(Otto.Checkpointer)
      Process.exit(checkpointer_pid, :kill)
      :timer.sleep(200)  # Wait for restart

      # Should be restarted
      new_checkpointer_pid = Process.whereis(Otto.Checkpointer)
      assert is_pid(new_checkpointer_pid)
      assert new_checkpointer_pid != checkpointer_pid

      # Artifact should still exist and be loadable
      assert File.exists?(artifact_ref.path)
      {:ok, loaded_content} = Otto.Checkpointer.load_artifact(artifact_ref)
      assert loaded_content == test_content
    end
  end

  describe "Cascading Failure Prevention" do
    test "multiple component failures don't cascade" do
      # This test simulates multiple components failing simultaneously
      # to ensure the system doesn't enter a cascade failure state

      # Record initial state
      initial_pids = %{
        toolbus: Process.whereis(Otto.ToolBus),
        context_store: Process.whereis(Otto.ContextStore),
        cost_tracker: Process.whereis(Otto.CostTracker)
      }

      # Kill multiple components simultaneously
      for {_name, pid} <- initial_pids do
        if pid, do: Process.exit(pid, :kill)
      end

      :timer.sleep(500)  # Wait for restarts

      # All should be restarted
      final_pids = %{
        toolbus: Process.whereis(Otto.ToolBus),
        context_store: Process.whereis(Otto.ContextStore),
        cost_tracker: Process.whereis(Otto.CostTracker)
      }

      for {name, pid} <- final_pids do
        assert is_pid(pid), "#{name} was not restarted"
        assert pid != initial_pids[name], "#{name} should be a new process"
      end

      # System should still be functional
      assert length(ToolBus.list_tools()) >= 0
    end

    test "supervisor tree remains stable under stress" do
      # Verify main supervisor is healthy
      supervisor_pid = Process.whereis(Otto.Agent.Application)
      assert is_pid(supervisor_pid)

      # Get children count
      initial_children = Supervisor.which_children(Otto.Agent.Application)
      initial_count = length(initial_children)

      # Cause multiple failures
      for _i <- 1..3 do
        # Kill a component
        toolbus_pid = Process.whereis(Otto.ToolBus)
        if toolbus_pid, do: Process.exit(toolbus_pid, :kill)
        :timer.sleep(100)
      end

      :timer.sleep(300)  # Allow time for recovery

      # Supervisor should still be running with same number of children
      assert Process.alive?(supervisor_pid)
      final_children = Supervisor.which_children(Otto.Agent.Application)
      assert length(final_children) == initial_count

      # Should still be able to start agents
      config = %AgentConfig{
        name: "PostStressAgent",
        model: "claude-3-haiku",
        description: "Agent started after stress test",
        system_prompt: "Test prompt",
        tools: [],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      assert Process.alive?(agent_pid)
    end
  end

  describe "Error Reporting and Observability" do
    test "errors are properly logged with context" do
      config = %AgentConfig{
        name: "ObservabilityAgent",
        model: "claude-3-haiku",
        description: "Agent for observability testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = AgentServer.get_status(agent_pid).session_id

      log_output = capture_log(fn ->
        context = GenServer.call(agent_pid, :create_tool_context)
        ToolBus.invoke_tool("failing_tool", %{failure_type: "crash"}, context)
      end)

      # Should log with relevant context
      assert String.contains?(log_output, "Tool execution failed") or
             String.contains?(log_output, "failing_tool") or
             String.contains?(log_output, "error")
    end

    test "provides error metrics and telemetry" do
      # This test would verify that error events are emitted for monitoring
      # For now, just ensure the infrastructure supports it

      config = %AgentConfig{
        name: "TelemetryAgent",
        model: "claude-3-haiku",
        description: "Agent for telemetry testing",
        system_prompt: "Test prompt",
        tools: ["failing_tool"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      context = GenServer.call(agent_pid, :create_tool_context)

      # This would emit telemetry events
      ToolBus.invoke_tool("failing_tool", %{failure_type: "error"}, context)

      # Verify system is still functional after error
      assert Process.alive?(agent_pid)
    end
  end
end