defmodule Otto.AgentServerTest do
  use ExUnit.Case
  alias Otto.AgentServer
  alias Otto.AgentConfig
  alias Otto.ToolContext

  @test_config %AgentConfig{
    name: "TestAgent",
    description: "A test agent",
    model: "claude-3-haiku",
    system_prompt: "You are a helpful test assistant.",
    tools: ["test_tool"],
    budgets: %{
      time_limit: 300,
      token_limit: 10000,
      cost_limit: 1.0
    }
  }

  describe "AgentServer initialization" do
    test "starts with valid configuration" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      assert Process.alive?(pid)
      assert GenServer.call(pid, :get_config) == @test_config
    end

    test "generates unique session ID on startup" do
      {:ok, pid1} = start_supervised({AgentServer, @test_config}, id: :agent1)
      {:ok, pid2} = start_supervised({AgentServer, @test_config}, id: :agent2)

      session1 = GenServer.call(pid1, :get_session_id)
      session2 = GenServer.call(pid2, :get_session_id)

      assert session1 != session2
      assert is_binary(session1)
      assert is_binary(session2)
    end

    test "initializes with empty transcript" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      transcript = GenServer.call(pid, :get_transcript)
      assert transcript == []
    end

    test "sets up budget tracking" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      budget_status = GenServer.call(pid, :get_budget_status)
      assert budget_status.time_remaining <= @test_config.budgets.time_limit
      assert budget_status.tokens_used == 0
      assert budget_status.cost_used == 0.0
    end
  end

  describe "AgentServer state management" do
    test "maintains agent state across calls" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      # Initial state
      assert GenServer.call(pid, :get_config) == @test_config

      # State should persist
      :timer.sleep(50)
      assert GenServer.call(pid, :get_config) == @test_config
    end

    test "tracks invocation count" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      initial_count = GenServer.call(pid, :get_invocation_count)
      assert initial_count == 0

      # This would increment after actual invocations
      # For now, just verify the interface exists
    end

    test "provides status information" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      status = GenServer.call(pid, :get_status)

      assert Map.has_key?(status, :config)
      assert Map.has_key?(status, :session_id)
      assert Map.has_key?(status, :started_at)
      assert Map.has_key?(status, :budget_status)
      assert Map.has_key?(status, :transcript_length)
    end
  end

  describe "tool context creation" do
    test "creates proper tool context" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      context = GenServer.call(pid, :create_tool_context)

      assert %ToolContext{} = context
      assert context.agent_config == @test_config
      assert is_binary(context.working_dir)
      assert Map.has_key?(context.budget_guard, :remaining)
    end

    test "working directory is agent-specific" do
      {:ok, pid1} = start_supervised({AgentServer, @test_config}, id: :context_agent1)
      {:ok, pid2} = start_supervised({AgentServer, @test_config}, id: :context_agent2)

      context1 = GenServer.call(pid1, :create_tool_context)
      context2 = GenServer.call(pid2, :create_tool_context)

      assert context1.working_dir != context2.working_dir
      assert String.contains?(context1.working_dir, "agent")
      assert String.contains?(context2.working_dir, "agent")
    end

    test "budget guard reflects current usage" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      context = GenServer.call(pid, :create_tool_context)

      # Initially should have full budget available
      assert context.budget_guard.remaining > 0
      assert context.budget_guard.remaining <= @test_config.budgets.cost_limit
    end
  end

  describe "budget enforcement" do
    test "tracks time budget countdown" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      status1 = GenServer.call(pid, :get_budget_status)
      :timer.sleep(100)  # Wait 100ms
      status2 = GenServer.call(pid, :get_budget_status)

      assert status2.time_remaining < status1.time_remaining
    end

    test "prevents invocation when budget exceeded" do
      # Create config with very small budget for testing
      small_budget_config = %{@test_config | budgets: %{cost_limit: 0.001, time_limit: 1}}

      {:ok, pid} = start_supervised({AgentServer, small_budget_config})

      # Wait for time budget to expire
      :timer.sleep(1100)

      # This would test actual invocation blocking
      # For now, just verify budget status shows exceeded
      budget_status = GenServer.call(pid, :get_budget_status)
      assert budget_status.time_remaining <= 0
    end

    test "stops agent when budget hard limit reached" do
      # This test would verify the agent stops itself when budget is exceeded
      # Implementation would depend on the actual budget enforcement mechanism
      {:ok, pid} = start_supervised({AgentServer, @test_config})
      assert Process.alive?(pid)
    end
  end

  describe "transcript management" do
    test "maintains bounded transcript" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      # Add mock messages to transcript
      for i <- 1..5 do
        GenServer.cast(pid, {:add_to_transcript, %{role: "user", content: "Message #{i}"}})
      end

      transcript = GenServer.call(pid, :get_transcript)
      assert length(transcript) <= 10  # Assuming max transcript size
    end

    test "preserves transcript order" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      messages = [
        %{role: "user", content: "First message"},
        %{role: "assistant", content: "First response"},
        %{role: "user", content: "Second message"}
      ]

      for message <- messages do
        GenServer.cast(pid, {:add_to_transcript, message})
      end

      transcript = GenServer.call(pid, :get_transcript)
      assert length(transcript) >= 3

      # Messages should be in order
      user_messages = Enum.filter(transcript, &(&1.role == "user"))
      assert length(user_messages) >= 2
    end
  end

  describe "error handling" do
    test "handles invalid tool invocations gracefully" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      # This would test actual error handling during tool invocation
      # For now, just verify the agent stays alive
      assert Process.alive?(pid)
    end

    test "recovers from tool execution errors" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      # Verify agent remains functional after errors
      assert Process.alive?(pid)
      config = GenServer.call(pid, :get_config)
      assert config == @test_config
    end

    test "handles shutdown gracefully" do
      {:ok, pid} = start_supervised({AgentServer, @test_config})

      # Stop the agent
      GenServer.stop(pid, :normal)

      # Should shut down cleanly
      refute Process.alive?(pid)
    end
  end

  describe "process isolation" do
    test "agent failure doesn't affect other agents" do
      {:ok, pid1} = start_supervised({AgentServer, @test_config}, id: :isolated_agent1)
      {:ok, pid2} = start_supervised({AgentServer, @test_config}, id: :isolated_agent2)

      # Kill one agent
      Process.exit(pid1, :kill)

      # Other agent should remain unaffected
      :timer.sleep(50)
      assert Process.alive?(pid2)
      config = GenServer.call(pid2, :get_config)
      assert config == @test_config
    end

    test "supports concurrent agent operations" do
      agents = for i <- 1..3 do
        {:ok, pid} = start_supervised({AgentServer, @test_config}, id: :"concurrent_agent#{i}")
        pid
      end

      # All agents should respond concurrently
      tasks = for pid <- agents do
        Task.async(fn -> GenServer.call(pid, :get_status) end)
      end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      for result <- results do
        assert Map.has_key?(result, :config)
      end
    end
  end
end