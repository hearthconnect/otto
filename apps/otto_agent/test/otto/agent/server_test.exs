defmodule Otto.Agent.ServerTest do
  use ExUnit.Case, async: true

  alias Otto.Agent.{Config, Server}

  setup do
    config = %Config{
      name: "test-agent",
      system_prompt: "You are a test agent",
      tools: ["fs_read", "fs_write"],
      working_dir: "/tmp/test",
      budgets: %{
        time_seconds: 60,
        max_tokens: 1000,
        max_cost_dollars: 5.0
      }
    }

    {:ok, config: config}
  end

  describe "start_link/2" do
    test "starts server with valid configuration", %{config: config} do
      assert {:ok, pid} = Server.start_link(config, session_id: "test-123")
      assert Process.alive?(pid)

      # Clean up
      Server.stop(pid)
    end

    test "generates session_id if not provided", %{config: config} do
      assert {:ok, pid} = Server.start_link(config)

      assert {:ok, state} = Server.get_state(pid)
      assert is_binary(state.session_id)
      assert byte_size(state.session_id) == 32  # 16 bytes hex-encoded

      Server.stop(pid)
    end

    test "initializes state correctly", %{config: config} do
      assert {:ok, pid} = Server.start_link(config, session_id: "test-session")

      assert {:ok, state} = Server.get_state(pid)
      assert state.config == config
      assert state.session_id == "test-session"
      assert state.transcript == []
      assert state.budgets.time_remaining == 60
      assert state.budgets.tokens_used == 0
      assert state.budgets.cost_used == 0.0

      Server.stop(pid)
    end
  end

  describe "invoke/2" do
    test "handles simple invocation", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-invoke")

      request = %{
        input: "Hello, agent!",
        context: %{user_id: "test-user"}
      }

      assert {:ok, result} = Server.invoke(pid, request)
      assert result.success == true
      assert String.contains?(result.output, "Hello, agent!")
      assert is_list(result.transcript)
      assert length(result.transcript) == 2  # user input + agent output

      Server.stop(pid)
    end

    test "records transcript entries correctly", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-transcript")

      request = %{input: "Test message", context: %{}}

      assert {:ok, result} = Server.invoke(pid, request)

      # Check transcript structure
      assert length(result.transcript) == 2

      [user_entry, agent_entry] = result.transcript

      assert user_entry.type == :user_input
      assert user_entry.content == "Test message"
      assert %DateTime{} = user_entry.timestamp

      assert agent_entry.type == :agent_output
      assert String.contains?(agent_entry.content, "Test message")
      assert %DateTime{} = agent_entry.timestamp

      Server.stop(pid)
    end

    test "includes budget status in result", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-budget")

      request = %{input: "Test", context: %{}}

      assert {:ok, result} = Server.invoke(pid, request)
      assert Map.has_key?(result, :budget_status)
      assert result.budget_status.time_remaining <= 60
      assert result.budget_status.tokens_used == 0
      assert result.budget_status.cost_used == 0.0

      Server.stop(pid)
    end
  end

  describe "budget enforcement" do
    test "rejects invocation when time budget exceeded", %{config: config} do
      # Set very short time budget
      config = %{config | budgets: %{time_seconds: 0}}
      {:ok, pid} = Server.start_link(config, session_id: "test-time-budget")

      # Wait a moment to ensure time passes
      Process.sleep(10)

      request = %{input: "Test", context: %{}}

      assert {:error, {:budget_exceeded, :time_budget_exceeded}} = Server.invoke(pid, request)

      Server.stop(pid)
    end

    test "handles infinite budgets correctly", %{config: config} do
      config = %{config | budgets: %{}}
      {:ok, pid} = Server.start_link(config, session_id: "test-infinite-budget")

      request = %{input: "Test", context: %{}}

      assert {:ok, result} = Server.invoke(pid, request)
      assert result.success == true

      Server.stop(pid)
    end
  end

  describe "tool invocation" do
    test "allows invocation of configured tools", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-tools")

      {:ok, state} = Server.get_state(pid)

      assert {:ok, result, new_state} = Server.invoke_tool(state, "fs_read", %{file_path: "test.txt"})
      assert result.tool == "fs_read"
      assert is_list(new_state.transcript)

      Server.stop(pid)
    end

    test "rejects invocation of non-configured tools", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-tool-rejection")

      {:ok, state} = Server.get_state(pid)

      assert {:error, {:tool_not_allowed, "http"}, _state} =
        Server.invoke_tool(state, "http", %{url: "https://example.com"})

      Server.stop(pid)
    end
  end

  describe "state management" do
    test "get_state returns current state", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-state")

      assert {:ok, state} = Server.get_state(pid)
      assert %Server{} = state
      assert state.config == config

      Server.stop(pid)
    end

    test "state persists across invocations", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-persistence")

      # First invocation
      request1 = %{input: "First message", context: %{}}
      assert {:ok, _result1} = Server.invoke(pid, request1)

      # Second invocation
      request2 = %{input: "Second message", context: %{}}
      assert {:ok, result2} = Server.invoke(pid, request2)

      # Transcript should contain both invocations
      assert length(result2.transcript) == 4  # 2 user inputs + 2 agent outputs

      Server.stop(pid)
    end
  end

  describe "error handling" do
    test "handles malformed requests gracefully", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-errors")

      # Request without input
      request = %{context: %{}}

      # This should not crash the server
      result = Server.invoke(pid, request)
      assert {:ok, _} = result

      Server.stop(pid)
    end
  end

  describe "stop/1" do
    test "stops server gracefully", %{config: config} do
      {:ok, pid} = Server.start_link(config, session_id: "test-stop")
      assert Process.alive?(pid)

      assert :ok = Server.stop(pid)

      # Give it a moment to stop
      Process.sleep(10)
      refute Process.alive?(pid)
    end
  end
end