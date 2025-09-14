defmodule Otto.ToolBusTest do
  use ExUnit.Case
  alias Otto.ToolBus

  defmodule TestTool do
    @behaviour Otto.Tool
    def name, do: "test_tool"
    def permissions, do: [:read]
    def call(params, _context), do: {:ok, params}
  end

  defmodule WriteTool do
    @behaviour Otto.Tool
    def name, do: "write_tool"
    def permissions, do: [:write]
    def call(params, _context), do: {:ok, %{written: params}}
  end

  defmodule ExecTool do
    @behaviour Otto.Tool
    def name, do: "exec_tool"
    def permissions, do: [:exec]
    def call(_params, _context), do: {:error, :blocked}
  end

  setup do
    # Start ToolBus for each test
    {:ok, pid} = start_supervised(ToolBus)
    {:ok, toolbus: pid}
  end

  describe "ToolBus registry" do
    test "starts without any tools registered" do
      assert ToolBus.list_tools() == []
    end

    test "can register a tool module" do
      assert :ok = ToolBus.register_tool(TestTool)
      tools = ToolBus.list_tools()
      assert length(tools) == 1

      tool_info = hd(tools)
      assert tool_info.name == "test_tool"
      assert tool_info.module == TestTool
      assert tool_info.permissions == [:read]
    end

    test "can register multiple tools" do
      assert :ok = ToolBus.register_tool(TestTool)
      assert :ok = ToolBus.register_tool(WriteTool)

      tools = ToolBus.list_tools()
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1.name)
      assert "test_tool" in tool_names
      assert "write_tool" in tool_names
    end

    test "rejects duplicate tool registration" do
      assert :ok = ToolBus.register_tool(TestTool)
      assert {:error, :already_registered} = ToolBus.register_tool(TestTool)
    end

    test "can lookup tool by name" do
      ToolBus.register_tool(TestTool)

      assert {:ok, tool_info} = ToolBus.get_tool("test_tool")
      assert tool_info.name == "test_tool"
      assert tool_info.module == TestTool
      assert tool_info.permissions == [:read]
    end

    test "returns error for unknown tool" do
      assert {:error, :not_found} = ToolBus.get_tool("unknown_tool")
    end

    test "supports hot-reload by re-registering tools" do
      # Initial registration
      ToolBus.register_tool(TestTool)
      assert {:ok, _} = ToolBus.get_tool("test_tool")

      # Re-register should update the tool
      assert :ok = ToolBus.reload_tool(TestTool)
      assert {:ok, tool_info} = ToolBus.get_tool("test_tool")
      assert tool_info.module == TestTool
    end

    test "can unregister tools" do
      ToolBus.register_tool(TestTool)
      assert {:ok, _} = ToolBus.get_tool("test_tool")

      assert :ok = ToolBus.unregister_tool("test_tool")
      assert {:error, :not_found} = ToolBus.get_tool("test_tool")
    end
  end

  describe "tool invocation" do
    setup do
      ToolBus.register_tool(TestTool)
      ToolBus.register_tool(WriteTool)
      ToolBus.register_tool(ExecTool)
      :ok
    end

    test "can invoke tool by name with params and context" do
      context = %Otto.ToolContext{
        agent_config: %{name: "test", allowed_permissions: [:read]},
        working_dir: "/tmp",
        budget_guard: %{remaining: 1000}
      }

      params = %{message: "hello"}

      assert {:ok, result} = ToolBus.invoke_tool("test_tool", params, context)
      assert result == params
    end

    test "returns error for unknown tool invocation" do
      context = %Otto.ToolContext{
        agent_config: %{},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      assert {:error, :tool_not_found} = ToolBus.invoke_tool("unknown", %{}, context)
    end

    test "enforces permission checking on invocation" do
      context = %Otto.ToolContext{
        agent_config: %{allowed_permissions: [:read]},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      # Should succeed - read permission allowed
      assert {:ok, _} = ToolBus.invoke_tool("test_tool", %{}, context)

      # Should fail - write permission not allowed
      assert {:error, :permission_denied} =
        ToolBus.invoke_tool("write_tool", %{}, context)

      # Should fail - exec permission not allowed
      assert {:error, :permission_denied} =
        ToolBus.invoke_tool("exec_tool", %{}, context)
    end

    test "tool execution errors are properly returned" do
      context = %Otto.ToolContext{
        agent_config: %{allowed_permissions: [:exec]},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      # Tool returns error tuple
      assert {:error, :blocked} = ToolBus.invoke_tool("exec_tool", %{}, context)
    end
  end

  describe "permission enforcement" do
    setup do
      ToolBus.register_tool(TestTool)
      ToolBus.register_tool(WriteTool)
      ToolBus.register_tool(ExecTool)
      :ok
    end

    test "allows invocation when tool permissions are subset of allowed" do
      context = %Otto.ToolContext{
        agent_config: %{allowed_permissions: [:read, :write, :exec]},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      assert {:ok, _} = ToolBus.invoke_tool("test_tool", %{}, context)
      assert {:ok, _} = ToolBus.invoke_tool("write_tool", %{}, context)
    end

    test "blocks invocation when tool requires disallowed permissions" do
      context = %Otto.ToolContext{
        agent_config: %{allowed_permissions: [:read]},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      # Read tool should work
      assert {:ok, _} = ToolBus.invoke_tool("test_tool", %{}, context)

      # Write tool should be blocked
      assert {:error, :permission_denied} =
        ToolBus.invoke_tool("write_tool", %{}, context)

      # Exec tool should be blocked
      assert {:error, :permission_denied} =
        ToolBus.invoke_tool("exec_tool", %{}, context)
    end

    test "handles missing allowed_permissions gracefully" do
      context = %Otto.ToolContext{
        agent_config: %{},  # No allowed_permissions key
        working_dir: "/tmp",
        budget_guard: %{}
      }

      # Should deny all tools when no permissions specified
      assert {:error, :permission_denied} =
        ToolBus.invoke_tool("test_tool", %{}, context)
    end
  end

  describe "concurrent access" do
    test "handles concurrent tool registration" do
      tasks = for i <- 1..10 do
        Task.async(fn ->
          tool_module = Module.concat([TestModule, "Tool#{i}"])
          ToolBus.register_tool(tool_module)
        end)
      end

      # Not all should succeed due to module not existing, but no crashes
      results = Enum.map(tasks, &Task.await/1)
      assert is_list(results)
    end

    test "handles concurrent tool invocation" do
      ToolBus.register_tool(TestTool)

      context = %Otto.ToolContext{
        agent_config: %{allowed_permissions: [:read]},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      tasks = for i <- 1..10 do
        Task.async(fn ->
          ToolBus.invoke_tool("test_tool", %{id: i}, context)
        end)
      end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      for result <- results do
        assert match?({:ok, _}, result)
      end
    end
  end
end