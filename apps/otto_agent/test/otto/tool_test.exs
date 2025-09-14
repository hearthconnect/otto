defmodule Otto.ToolTest do
  use ExUnit.Case
  doctest Otto.Tool

  defmodule TestTool do
    @behaviour Otto.Tool

    @impl Otto.Tool
    def name, do: "test_tool"

    @impl Otto.Tool
    def permissions, do: [:read, :write]

    @impl Otto.Tool
    def call(params, context) do
      {:ok, %{params: params, context: context}}
    end
  end

  defmodule UnsafeTool do
    @behaviour Otto.Tool

    @impl Otto.Tool
    def name, do: "unsafe_tool"

    @impl Otto.Tool
    def permissions, do: [:exec]

    @impl Otto.Tool
    def call(_params, _context) do
      {:ok, "unsafe operation completed"}
    end
  end

  describe "Otto.Tool behaviour" do
    test "defines required callbacks" do
      # Verify the behaviour exists and defines the expected callbacks
      assert function_exported?(Otto.Tool, :behaviour_info, 1)
      callbacks = Otto.Tool.behaviour_info(:callbacks)

      expected_callbacks = [
        {:name, 0},
        {:permissions, 0},
        {:call, 2}
      ]

      for callback <- expected_callbacks do
        assert callback in callbacks, "Expected callback #{inspect(callback)} not found"
      end
    end

    test "TestTool implements all required callbacks" do
      assert TestTool.name() == "test_tool"
      assert TestTool.permissions() == [:read, :write]

      context = %Otto.ToolContext{
        agent_config: %{name: "test_agent"},
        working_dir: "/tmp/test",
        budget_guard: %{remaining: 1000}
      }

      params = %{operation: "test"}

      assert {:ok, result} = TestTool.call(params, context)
      assert result.params == params
      assert result.context == context
    end

    test "permissions are correctly specified as list of atoms" do
      valid_permissions = [:read, :write, :exec]

      for perm <- TestTool.permissions() do
        assert perm in valid_permissions, "Invalid permission: #{perm}"
        assert is_atom(perm), "Permission must be an atom"
      end
    end

    test "name returns string identifier" do
      name = TestTool.name()
      assert is_binary(name)
      assert String.length(name) > 0
    end

    test "call returns ok/error tuple" do
      context = %Otto.ToolContext{
        agent_config: %{},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      result = TestTool.call(%{}, context)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "tool context structure" do
    test "ToolContext has required fields" do
      context = %Otto.ToolContext{
        agent_config: %{name: "test"},
        working_dir: "/tmp/test",
        budget_guard: %{remaining: 1000}
      }

      assert Map.has_key?(context, :agent_config)
      assert Map.has_key?(context, :working_dir)
      assert Map.has_key?(context, :budget_guard)
    end

    test "working_dir provides sandbox isolation" do
      context = %Otto.ToolContext{
        agent_config: %{},
        working_dir: "/tmp/agent_123",
        budget_guard: %{}
      }

      assert is_binary(context.working_dir)
      assert String.contains?(context.working_dir, "agent_123")
    end
  end

  describe "permission validation" do
    test "tools can specify multiple permission types" do
      permissions = TestTool.permissions()
      assert :read in permissions
      assert :write in permissions
      assert length(permissions) >= 1
    end

    test "exec permission is distinctly identifiable" do
      exec_permissions = UnsafeTool.permissions()
      assert :exec in exec_permissions
    end

    test "permissions list contains only valid permission atoms" do
      valid_perms = [:read, :write, :exec]

      all_permissions = TestTool.permissions() ++ UnsafeTool.permissions()
      for perm <- all_permissions do
        assert perm in valid_perms, "Invalid permission: #{inspect(perm)}"
      end
    end
  end
end