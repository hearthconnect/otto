defmodule Otto.Tool.BusTest do
  use ExUnit.Case, async: true

  alias Otto.Tool.Bus

  defmodule TestTool do
    @behaviour Otto.Tool

    def execute(_args, _context), do: {:ok, "test result"}
    def validate_args(_args), do: :ok
    def sandbox_config, do: %{timeout: 5000, memory_limit: 100_000, filesystem_access: :none}
    def metadata, do: %{name: "test_tool", description: "A test tool", parameters: %{}}
  end

  setup do
    {:ok, pid} = Bus.start_link(name: :"test_bus_#{:rand.uniform(1000)}")
    {:ok, bus: pid}
  end

  describe "tool registration" do
    test "registers a tool successfully", %{bus: bus} do
      assert :ok = Bus.register_tool(bus, "test_tool", TestTool)
      assert {:ok, TestTool} = Bus.get_tool(bus, "test_tool")
    end

    test "prevents duplicate tool registration", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)
      assert {:error, :already_registered} = Bus.register_tool(bus, "test_tool", TestTool)
    end

    test "lists all registered tools", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)
      assert ["test_tool"] = Bus.list_tools(bus)
    end

    test "unregisters a tool", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)
      assert :ok = Bus.unregister_tool(bus, "test_tool")
      assert {:error, :not_found} = Bus.get_tool(bus, "test_tool")
    end
  end

  describe "permission checking" do
    test "allows tool execution when permission granted", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)
      :ok = Bus.grant_permission(bus, "agent_1", "test_tool")

      assert :ok = Bus.check_permission(bus, "agent_1", "test_tool")
    end

    test "denies tool execution when no permission", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)

      assert {:error, :permission_denied} = Bus.check_permission(bus, "agent_1", "test_tool")
    end

    test "revokes tool permission", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)
      :ok = Bus.grant_permission(bus, "agent_1", "test_tool")
      :ok = Bus.revoke_permission(bus, "agent_1", "test_tool")

      assert {:error, :permission_denied} = Bus.check_permission(bus, "agent_1", "test_tool")
    end
  end

  describe "tool execution" do
    test "executes tool with valid permissions", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)
      :ok = Bus.grant_permission(bus, "agent_1", "test_tool")

      context = %{agent_id: "agent_1", session_id: "session_1"}
      assert {:ok, "test result"} = Bus.execute_tool(bus, "test_tool", %{}, context)
    end

    test "rejects execution without permission", %{bus: bus} do
      :ok = Bus.register_tool(bus, "test_tool", TestTool)

      context = %{agent_id: "agent_1", session_id: "session_1"}
      assert {:error, :permission_denied} = Bus.execute_tool(bus, "test_tool", %{}, context)
    end

    test "rejects execution of unregistered tool", %{bus: bus} do
      context = %{agent_id: "agent_1", session_id: "session_1"}
      assert {:error, :tool_not_found} = Bus.execute_tool(bus, "unknown_tool", %{}, context)
    end
  end
end