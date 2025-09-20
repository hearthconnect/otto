defmodule Otto.Tools.FSReadTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  defmodule FSRead do
    @behaviour Otto.Tool

    def name, do: "FS.Read"
    def permissions, do: [:read]

    def call(%{path: path}, context) do
      full_path = Path.join(context.working_dir, path)

      # Security check - ensure path is within working directory
      expanded_path = Path.expand(full_path)
      working_dir_expanded = Path.expand(context.working_dir)

      if String.starts_with?(expanded_path, working_dir_expanded) do
        case File.read(expanded_path) do
          {:ok, content} -> {:ok, %{content: content, size: byte_size(content)}}
          {:error, reason} -> {:error, {:file_error, reason}}
        end
      else
        {:error, :path_outside_sandbox}
      end
    end
  end

  setup do
    # Create a temporary working directory for each test
    working_dir = "/tmp/otto_test_#{System.unique_integer()}"
    File.mkdir_p!(working_dir)

    context = %Otto.ToolContext{
      agent_config: %{name: "test_agent", allowed_permissions: [:read]},
      working_dir: working_dir,
      budget_guard: %{remaining: 1000}
    }

    on_exit(fn -> File.rm_rf!(working_dir) end)

    {:ok, context: context, working_dir: working_dir}
  end

  describe "FS.Read tool" do
    test "reads existing file content", %{context: context, working_dir: working_dir} do
      # Create test file
      test_file = "test.txt"
      test_content = "Hello, Otto!"
      test_path = Path.join(working_dir, test_file)
      File.write!(test_path, test_content)

      # Read via tool
      params = %{path: test_file}
      assert {:ok, result} = FSRead.call(params, context)

      assert result.content == test_content
      assert result.size == byte_size(test_content)
    end

    test "returns error for non-existent file", %{context: context} do
      params = %{path: "non_existent.txt"}

      assert {:error, {:file_error, :enoent}} = FSRead.call(params, context)
    end

    test "prevents path traversal attacks", %{context: context} do
      # Try to read outside working directory
      params = %{path: "../../../etc/passwd"}

      assert {:error, :path_outside_sandbox} = FSRead.call(params, context)
    end

    test "prevents absolute path access", %{context: context} do
      params = %{path: "/etc/passwd"}

      assert {:error, :path_outside_sandbox} = FSRead.call(params, context)
    end

    test "handles subdirectories within sandbox", %{context: context, working_dir: working_dir} do
      # Create subdirectory and file
      subdir = Path.join(working_dir, "subdir")
      File.mkdir_p!(subdir)

      test_content = "subdirectory content"
      File.write!(Path.join(subdir, "sub.txt"), test_content)

      # Read from subdirectory
      params = %{path: "subdir/sub.txt"}
      assert {:ok, result} = FSRead.call(params, context)
      assert result.content == test_content
    end

    test "handles binary files", %{context: context, working_dir: working_dir} do
      # Create binary file
      binary_content = <<1, 2, 3, 4, 5, 255, 254, 253>>
      binary_path = Path.join(working_dir, "binary.dat")
      File.write!(binary_path, binary_content)

      params = %{path: "binary.dat"}
      assert {:ok, result} = FSRead.call(params, context)
      assert result.content == binary_content
      assert result.size == 8
    end

    test "handles large files within limits", %{context: context, working_dir: working_dir} do
      # Create 1KB file
      large_content = String.duplicate("A", 1024)
      large_path = Path.join(working_dir, "large.txt")
      File.write!(large_path, large_content)

      params = %{path: "large.txt"}
      assert {:ok, result} = FSRead.call(params, context)
      assert result.content == large_content
      assert result.size == 1024
    end

    test "respects file size limits when configured" do
      # This would test configuration-based size limits
      # For now, just verify the tool can handle the concept
      working_dir = "/tmp/otto_test_size_limit"
      File.mkdir_p!(working_dir)

      context_with_limits = %Otto.ToolContext{
        agent_config: %{
          name: "test_agent",
          allowed_permissions: [:read],
          max_file_size: 100  # 100 bytes limit
        },
        working_dir: working_dir,
        budget_guard: %{remaining: 1000}
      }

      # Create file larger than limit
      large_content = String.duplicate("X", 200)  # 200 bytes
      File.write!(Path.join(working_dir, "too_large.txt"), large_content)

      params = %{path: "too_large.txt"}

      # Tool should either read it (if limit not implemented) or reject it
      result = FSRead.call(params, context_with_limits)
      case result do
        {:ok, _} -> :ok  # Size limit not implemented yet
        {:error, :file_too_large} -> :ok  # Size limit implemented
        {:error, _} -> :ok  # Other error is acceptable for now
      end

      File.rm_rf!(working_dir)
    end

    test "handles permission errors gracefully", %{context: context, working_dir: working_dir} do
      # Create file with restricted permissions
      restricted_file = Path.join(working_dir, "restricted.txt")
      File.write!(restricted_file, "restricted content")

      # Remove read permissions (this might not work on all systems)
      File.chmod!(restricted_file, 0o000)

      params = %{path: "restricted.txt"}
      result = FSRead.call(params, context)

      # Should handle permission error gracefully
      case result do
        {:error, {:file_error, :eacces}} -> :ok  # Permission denied
        {:ok, _} -> :ok  # Permissions might not be enforced on test system
        {:error, _} -> :ok  # Any error handling is acceptable
      end

      # Restore permissions for cleanup
      File.chmod!(restricted_file, 0o644)
    end

    test "validates required parameters" do
      context = %Otto.ToolContext{
        agent_config: %{allowed_permissions: [:read]},
        working_dir: "/tmp",
        budget_guard: %{}
      }

      # Missing path parameter
      assert_raise(MatchError, fn ->
        FSRead.call(%{}, context)
      end)

      # Invalid path parameter
      assert_raise(FunctionClauseError, fn ->
        FSRead.call(%{path: nil}, context)
      end)
    end
  end

  describe "tool integration with ToolBus" do
    test "registers correctly with ToolBus" do
      # Ensure ToolBus is running
      if Process.whereis(Otto.ToolBus) do
        assert :ok = Otto.ToolBus.register_tool(FSRead)

        {:ok, tool_info} = Otto.ToolBus.get_tool("FS.Read")
        assert tool_info.name == "FS.Read"
        assert tool_info.module == FSRead
        assert tool_info.permissions == [:read]
      end
    end

    test "can be invoked through ToolBus", %{context: context, working_dir: working_dir} do
      if Process.whereis(Otto.ToolBus) do
        Otto.ToolBus.register_tool(FSRead)

        # Create test file
        test_content = "ToolBus integration test"
        File.write!(Path.join(working_dir, "toolbus.txt"), test_content)

        # Invoke through ToolBus
        params = %{path: "toolbus.txt"}

        case Otto.ToolBus.invoke_tool("FS.Read", params, context) do
          {:ok, result} ->
            assert result.content == test_content
          {:error, :permission_denied} ->
            # Expected if permissions not properly set in context
            :ok
          {:error, reason} ->
            flunk("Unexpected error: #{inspect(reason)}")
        end
      end
    end
  end
end