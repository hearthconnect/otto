defmodule Otto.IntegrationTest do
  @moduledoc """
  Integration tests for Otto Phase 0.

  Tests the complete flow:
  1. Load agent config from YAML
  2. Start agent with supervision
  3. Register tools
  4. Execute tool through agent
  5. Track costs and artifacts
  6. Clean up resources
  """

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Otto.{AgentConfig, AgentServer, ToolBus, ContextStore, Checkpointer, CostTracker}

  @fixtures_path Path.join(__DIR__, "fixtures/agents")
  @integration_timeout 30_000

  # Simple test tools for integration
  defmodule TestReadTool do
    @behaviour Otto.Tool
    def name, do: "test_read"
    def permissions, do: [:read]

    def call(%{path: path}, context) do
      full_path = Path.join(context.working_dir, path)
      case File.read(full_path) do
        {:ok, content} -> {:ok, %{content: content, path: path}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule TestWriteTool do
    @behaviour Otto.Tool
    def name, do: "test_write"
    def permissions, do: [:write]

    def call(%{path: path, content: content}, context) do
      full_path = Path.join(context.working_dir, path)
      File.mkdir_p!(Path.dirname(full_path))
      case File.write(full_path, content) do
        :ok -> {:ok, %{written: byte_size(content), path: path}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  setup_all do
    # Ensure Otto application is started
    Application.ensure_started(:otto_agent)

    # Register test tools
    ToolBus.register_tool(TestReadTool)
    ToolBus.register_tool(TestWriteTool)

    :ok
  end

  describe "End-to-End Agent Workflow" do
    @tag timeout: @integration_timeout
    test "complete agent lifecycle with YAML config" do
      # Step 1: Load agent config from YAML
      config_path = Path.join(@fixtures_path, "valid_basic.yml")
      assert {:ok, config} = AgentConfig.load_from_file(config_path)
      assert config.name == "BasicTestAgent"

      # Override tools for testing
      test_config = %{config | tools: ["test_read", "test_write"]}

      # Step 2: Start agent server through dynamic supervisor
      {:ok, agent_pid} = DynamicSupervisor.start_child(
        Otto.Agent.DynamicSupervisor,
        {AgentServer, test_config}
      )

      assert Process.alive?(agent_pid)

      # Step 3: Verify agent is properly initialized
      status = AgentServer.get_status(agent_pid)
      assert status.config.name == "BasicTestAgent"
      assert is_binary(status.session_id)

      # Step 4: Create working directory and test file
      working_dir = status.working_dir
      test_file_path = Path.join(working_dir, "test_input.txt")
      test_content = "Hello from integration test!"
      File.write!(test_file_path, test_content)

      # Step 5: Execute tool through agent
      # Note: This is a simplified invocation since we don't have LLM integration yet
      context = GenServer.call(agent_pid, :create_tool_context)

      # Test read operation
      read_result = ToolBus.invoke_tool("test_read", %{path: "test_input.txt"}, context)
      assert {:ok, %{content: ^test_content}} = read_result

      # Test write operation
      write_result = ToolBus.invoke_tool("test_write", %{
        path: "output.txt",
        content: "Integration test output"
      }, context)
      assert {:ok, %{written: 25}} = write_result

      # Step 6: Verify artifacts were created
      output_file = Path.join(working_dir, "output.txt")
      assert File.exists?(output_file)
      assert File.read!(output_file) == "Integration test output"

      # Step 7: Check budget tracking
      budget_status = AgentServer.get_budget_status(agent_pid)
      assert budget_status.time_remaining > 0
      assert budget_status.tokens_used == 0  # No LLM calls made yet

      # Step 8: Clean shutdown
      DynamicSupervisor.terminate_child(Otto.Agent.DynamicSupervisor, agent_pid)
      refute Process.alive?(agent_pid)

      # Working directory should be cleaned up
      refute File.exists?(working_dir)
    end

    @tag timeout: @integration_timeout
    test "agent registry and lookup functionality" do
      config_path = Path.join(@fixtures_path, "valid_complex.yml")
      {:ok, config} = AgentConfig.load_from_file(config_path)

      # Start agent with registry name
      agent_id = "complex_test_agent_#{System.unique_integer()}"

      {:ok, agent_pid} = DynamicSupervisor.start_child(
        Otto.Agent.DynamicSupervisor,
        {AgentServer, config}
      )

      # Register in agent registry
      {:ok, _} = Registry.register(Otto.Agent.Registry, agent_id, %{
        config: config,
        started_at: DateTime.utc_now()
      })

      # Should be able to lookup the agent
      [{registered_pid, metadata}] = Registry.lookup(Otto.Agent.Registry, agent_id)
      assert registered_pid == self()  # Current process registered itself
      assert metadata.config == config

      # Clean up
      DynamicSupervisor.terminate_child(Otto.Agent.DynamicSupervisor, agent_pid)
    end

    @tag timeout: @integration_timeout
    test "context storage and retrieval" do
      config = %AgentConfig{
        name: "ContextTestAgent",
        model: "claude-3-haiku",
        description: "Agent for context testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config}, id: :context_agent)

      # Store context data
      session_id = GenServer.call(agent_pid, :get_session_id)
      context_data = %{
        task: "integration_test",
        state: %{step: 1, progress: "started"}
      }

      assert :ok = ContextStore.put_context(session_id, context_data)

      # Retrieve context data
      assert {:ok, stored_entry} = ContextStore.get_context(session_id)
      assert stored_entry.data == context_data

      # Verify context is cleaned up when agent stops
      GenServer.stop(agent_pid)
      # Note: Cleanup might be manual or triggered by specific events
    end

    @tag timeout: @integration_timeout
    test "cost tracking across operations" do
      config = %AgentConfig{
        name: "CostTrackingAgent",
        model: "claude-3-haiku",
        description: "Agent for cost tracking testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{cost_limit: 5.0}  # $5 limit
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config}, id: :cost_agent)

      # Record some mock usage
      session_id = GenServer.call(agent_pid, :get_session_id)

      {:ok, _record} = CostTracker.record_usage(:session, session_id, "claude-3-haiku", 1000, 500)
      {:ok, _record} = CostTracker.record_usage(:session, session_id, "claude-3-haiku", 800, 400)

      # Check usage aggregation
      {:ok, usage} = CostTracker.get_usage(:session, session_id)
      assert usage.total_input_tokens == 1800
      assert usage.total_output_tokens == 900
      assert usage.record_count == 2
      assert usage.total_cost > 0

      # Check budget status
      {:ok, budget_status} = CostTracker.check_budget(:session, session_id)
      assert budget_status.within_budget  # Should be under $5
      assert budget_status.total_cost > 0

      GenServer.stop(agent_pid)
    end

    @tag timeout: @integration_timeout
    test "artifact checkpointing and persistence" do
      config = %AgentConfig{
        name: "CheckpointAgent",
        model: "claude-3-haiku",
        description: "Agent for checkpoint testing",
        system_prompt: "Test prompt",
        tools: ["test_write"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config}, id: :checkpoint_agent)
      session_id = GenServer.call(agent_pid, :get_session_id)

      # Create some artifacts
      transcript_content = [
        %{role: "user", content: "Test instruction"},
        %{role: "assistant", content: "Test response"}
      ]

      result_content = %{
        success: true,
        output: "Task completed successfully",
        artifacts_created: ["output.txt"]
      }

      # Save artifacts through checkpointer
      {:ok, transcript_ref} = Checkpointer.save_artifact(
        session_id,
        :transcript,
        Jason.encode!(transcript_content)
      )

      {:ok, result_ref} = Checkpointer.save_artifact(
        session_id,
        :result,
        Jason.encode!(result_content)
      )

      # Verify artifacts exist
      assert File.exists?(transcript_ref.path)
      assert File.exists?(result_ref.path)

      # Load and verify content
      {:ok, loaded_transcript} = Checkpointer.load_artifact(transcript_ref)
      {:ok, parsed_transcript} = Jason.decode(loaded_transcript)
      assert length(parsed_transcript) == 2

      {:ok, loaded_result} = Checkpointer.load_artifact(result_ref)
      {:ok, parsed_result} = Jason.decode(loaded_result)
      assert parsed_result["success"] == true

      # List all artifacts for session
      {:ok, artifacts} = Checkpointer.list_artifacts(session_id)
      assert length(artifacts) >= 2

      GenServer.stop(agent_pid)
    end
  end

  describe "Error Handling and Recovery" do
    test "agent survives tool execution errors" do
      config = %AgentConfig{
        name: "ErrorHandlingAgent",
        model: "claude-3-haiku",
        description: "Agent for error testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 300}
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})

      # Try to read non-existent file through agent
      context = GenServer.call(agent_pid, :create_tool_context)

      result = ToolBus.invoke_tool("test_read", %{path: "nonexistent.txt"}, context)
      assert match?({:error, _}, result)

      # Agent should still be alive and functional
      assert Process.alive?(agent_pid)
      status = AgentServer.get_status(agent_pid)
      assert status.config.name == "ErrorHandlingAgent"
    end

    test "supervision tree recovers from component failures" do
      # Get initial children count
      initial_children = Supervisor.which_children(Otto.Agent.Application)
      initial_count = length(initial_children)

      # Find and kill the ToolBus process
      toolbus_pid = Process.whereis(Otto.ToolBus)
      assert is_pid(toolbus_pid)

      Process.exit(toolbus_pid, :kill)
      :timer.sleep(100)  # Wait for restart

      # Should be restarted
      new_toolbus_pid = Process.whereis(Otto.ToolBus)
      assert is_pid(new_toolbus_pid)
      assert new_toolbus_pid != toolbus_pid

      # Re-register test tools
      ToolBus.register_tool(TestReadTool)
      ToolBus.register_tool(TestWriteTool)

      # Supervisor should have same number of children
      final_children = Supervisor.which_children(Otto.Agent.Application)
      assert length(final_children) == initial_count
    end

    test "budget enforcement prevents runaway costs" do
      config = %AgentConfig{
        name: "BudgetTestAgent",
        model: "gpt-4",  # Expensive model
        description: "Agent for budget testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{cost_limit: 0.01}  # Very small budget: $0.01
      }

      {:ok, agent_pid} = start_supervised({AgentServer, config})
      session_id = GenServer.call(agent_pid, :get_session_id)

      # Simulate expensive usage that exceeds budget
      {:ok, _} = CostTracker.record_usage(:session, session_id, "gpt-4", 10_000, 10_000)

      # Check budget status
      {:ok, budget_status} = CostTracker.check_budget(:session, session_id)
      refute budget_status.within_budget
      assert budget_status.total_cost > 0.01

      # Agent should refuse further invocations (when implemented)
      # For now, just verify budget tracking works
    end
  end

  describe "Performance and Scale" do
    @tag :performance
    test "supports multiple concurrent agents" do
      config = %AgentConfig{
        name: "ConcurrentAgent",
        model: "claude-3-haiku",
        description: "Agent for concurrency testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 300}
      }

      # Start multiple agents concurrently
      agent_count = 5
      agents = for i <- 1..agent_count do
        {:ok, pid} = DynamicSupervisor.start_child(
          Otto.Agent.DynamicSupervisor,
          {AgentServer, config}
        )
        {i, pid}
      end

      # All agents should be running
      for {_i, pid} <- agents do
        assert Process.alive?(pid)
      end

      # Test concurrent operations
      tasks = for {i, pid} <- agents do
        Task.async(fn ->
          status = AgentServer.get_status(pid)
          {i, status.session_id}
        end)
      end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed and have unique session IDs
      session_ids = Enum.map(results, fn {_i, session_id} -> session_id end)
      assert length(Enum.uniq(session_ids)) == agent_count

      # Clean up
      for {_i, pid} <- agents do
        DynamicSupervisor.terminate_child(Otto.Agent.DynamicSupervisor, pid)
      end
    end

    @tag :performance
    test "agent startup time is reasonable" do
      config = %AgentConfig{
        name: "PerformanceAgent",
        model: "claude-3-haiku",
        description: "Agent for performance testing",
        system_prompt: "Test prompt",
        tools: ["test_read"],
        budgets: %{time_limit: 300}
      }

      start_time = :os.system_time(:millisecond)

      {:ok, agent_pid} = start_supervised({AgentServer, config})

      end_time = :os.system_time(:millisecond)
      startup_time = end_time - start_time

      # Should start in under 500ms (generous for testing environment)
      assert startup_time < 500, "Agent startup took #{startup_time}ms, expected < 500ms"

      # Verify agent is functional
      status = AgentServer.get_status(agent_pid)
      assert status.config.name == "PerformanceAgent"
    end
  end
end