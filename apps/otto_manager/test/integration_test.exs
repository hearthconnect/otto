defmodule Otto.Manager.IntegrationTest do
  @moduledoc """
  Integration test for the core Otto Manager components without external dependencies.
  """
  use ExUnit.Case

  # Simple test tool for integration testing
  defmodule SimpleTestTool do
    @behaviour Otto.Tool

    def execute(%{"action" => "greet", "name" => name}, _context) do
      {:ok, "Hello, #{name}!"}
    end

    def execute(%{"action" => "error"}, _context) do
      {:error, "Test error"}
    end

    def execute(_args, _context) do
      {:error, "Unknown action"}
    end

    def validate_args(%{"action" => _action}), do: :ok
    def validate_args(_args), do: {:error, "action is required"}

    def sandbox_config do
      %{
        timeout: 5000,
        memory_limit: 100_000,
        filesystem_access: :none
      }
    end

    def metadata do
      %{
        name: "simple_test_tool",
        description: "A simple tool for testing",
        parameters: %{
          "action" => %{"type" => "string", "required" => true},
          "name" => %{"type" => "string", "required" => false}
        }
      }
    end
  end

  describe "Otto Manager integration" do
    test "can start and use core components" do
      # Start the core components manually for testing
      {:ok, registry} = Registry.start_link(keys: :unique, name: TestRegistry)
      {:ok, tool_bus} = Otto.Tool.Bus.start_link(name: TestToolBus)
      {:ok, context_store} = Otto.Manager.ContextStore.start_link(name: TestContextStore)
      {:ok, cost_tracker} = Otto.Manager.CostTracker.start_link(name: TestCostTracker)

      # Test tool registration and execution
      :ok = Otto.Tool.Bus.register_tool(TestToolBus, "simple_test", SimpleTestTool)
      :ok = Otto.Tool.Bus.grant_permission(TestToolBus, "test_agent", "simple_test")

      # Test tool execution
      context = %{agent_id: "test_agent", session_id: "test_session"}
      {:ok, result} = Otto.Tool.Bus.execute_tool(TestToolBus, "simple_test", %{"action" => "greet", "name" => "Otto"}, context)
      assert result == "Hello, Otto!"

      # Test context storage
      context_data = %{
        messages: [%{role: "user", content: "Hello"}],
        tools_used: ["simple_test"]
      }
      :ok = Otto.Manager.ContextStore.put(TestContextStore, "test_session", context_data)
      {:ok, stored_data} = Otto.Manager.ContextStore.get(TestContextStore, "test_session")
      assert stored_data.messages == context_data.messages

      # Test cost tracking
      :ok = Otto.Manager.CostTracker.record_tool_usage(TestCostTracker, %{
        agent_id: "test_agent",
        tool_name: "simple_test",
        execution_time_ms: 100,
        tokens_used: 50,
        api_calls: 1
      })

      stats = Otto.Manager.CostTracker.get_agent_stats(TestCostTracker, "test_agent")
      assert stats.total_tool_executions == 1
      assert stats.total_tokens == 50

      # Cleanup
      GenServer.stop(tool_bus)
      GenServer.stop(context_store)
      GenServer.stop(cost_tracker)
      GenServer.stop(registry)
    end

    test "tool permission system works correctly" do
      {:ok, tool_bus} = Otto.Tool.Bus.start_link(name: TestToolBusPermissions)

      :ok = Otto.Tool.Bus.register_tool(TestToolBusPermissions, "simple_test", SimpleTestTool)

      # Should fail without permission
      context = %{agent_id: "test_agent", session_id: "test_session"}
      assert {:error, :permission_denied} = Otto.Tool.Bus.execute_tool(TestToolBusPermissions, "simple_test", %{"action" => "greet"}, context)

      # Grant permission and try again
      :ok = Otto.Tool.Bus.grant_permission(TestToolBusPermissions, "test_agent", "simple_test")
      assert {:ok, "Hello, !"} = Otto.Tool.Bus.execute_tool(TestToolBusPermissions, "simple_test", %{"action" => "greet", "name" => ""}, context)

      GenServer.stop(tool_bus)
    end

    test "context store TTL functionality works" do
      {:ok, context_store} = Otto.Manager.ContextStore.start_link(name: TestContextStoreTTL)

      # Store with short TTL
      :ok = Otto.Manager.ContextStore.put(TestContextStoreTTL, "short_lived", %{data: "test"}, ttl: 50)

      # Should be available immediately
      assert {:ok, %{data: "test"}} = Otto.Manager.ContextStore.get(TestContextStoreTTL, "short_lived")

      # Wait for expiration
      Process.sleep(100)

      # Should be expired
      assert {:error, :not_found} = Otto.Manager.ContextStore.get(TestContextStoreTTL, "short_lived")

      GenServer.stop(context_store)
    end
  end
end