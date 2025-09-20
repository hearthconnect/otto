defmodule Otto.Tool.FS.WriteTest do
  use ExUnit.Case, async: true

  alias Otto.Tool.FS.Write

  setup do
    # Create a temporary directory for testing
    temp_dir = System.tmp_dir!() |> Path.join("otto_write_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(temp_dir)

    context = %{
      working_dir: temp_dir,
      session_id: "test-session"
    }

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir, context: context}
  end

  describe "execute/2" do
    test "writes new file successfully", %{temp_dir: temp_dir, context: context} do
      args = %{
        "file_path" => "new_file.txt",
        "content" => "Hello, World!"
      }

      assert {:ok, result} = Write.execute(args, context)
      assert String.ends_with?(result.file_path, "new_file.txt")
      assert result.size == 13
      assert result.mode == "write"

      # Verify file was actually written
      file_path = Path.join(temp_dir, "new_file.txt")
      assert File.read!(file_path) == "Hello, World!"
    end

    test "overwrites existing file", %{temp_dir: temp_dir, context: context} do
      file_path = Path.join(temp_dir, "existing.txt")
      File.write!(file_path, "Original content")

      args = %{
        "file_path" => "existing.txt",
        "content" => "New content"
      }

      assert {:ok, result} = Write.execute(args, context)
      assert result.mode == "write"

      # Verify file was overwritten
      assert File.read!(file_path) == "New content"
    end

    test "appends to existing file", %{temp_dir: temp_dir, context: context} do
      file_path = Path.join(temp_dir, "append_test.txt")
      File.write!(file_path, "Original\n")

      args = %{
        "file_path" => "append_test.txt",
        "content" => "Appended content",
        "mode" => "append"
      }

      assert {:ok, result} = Write.execute(args, context)
      assert result.mode == "append"

      # Verify content was appended
      assert File.read!(file_path) == "Original\nAppended content"
    end

    test "creates parent directories", %{temp_dir: temp_dir, context: context} do
      args = %{
        "file_path" => "deep/nested/directory/file.txt",
        "content" => "Deep file content"
      }

      assert {:ok, _result} = Write.execute(args, context)

      # Verify directories were created
      file_path = Path.join(temp_dir, "deep/nested/directory/file.txt")
      assert File.exists?(file_path)
      assert File.read!(file_path) == "Deep file content"
    end

    test "rejects paths outside working directory", %{context: context} do
      args = %{
        "file_path" => "../../../tmp/evil.txt",
        "content" => "Evil content"
      }

      assert {:error, "file_path cannot contain parent directory references"} = Write.execute(args, context)
    end

    test "rejects absolute paths outside working directory", %{context: context} do
      args = %{
        "file_path" => "/tmp/evil.txt",
        "content" => "Evil content"
      }

      assert {:error, "file_path is outside working directory"} = Write.execute(args, context)
    end

    test "rejects parent directory references", %{context: context} do
      args = %{
        "file_path" => "subdir/../../../evil.txt",
        "content" => "Evil content"
      }

      assert {:error, "file_path cannot contain parent directory references"} = Write.execute(args, context)
    end

    test "handles large content within limits", %{context: context} do
      large_content = String.duplicate("A", 1024)  # 1KB content

      args = %{
        "file_path" => "large.txt",
        "content" => large_content
      }

      assert {:ok, result} = Write.execute(args, context)
      assert result.size == 1024
    end
  end

  describe "validate_args/1" do
    test "validates valid write arguments" do
      args = %{
        "file_path" => "test.txt",
        "content" => "Hello"
      }

      assert :ok = Write.validate_args(args)
    end

    test "validates valid append arguments" do
      args = %{
        "file_path" => "test.txt",
        "content" => "Hello",
        "mode" => "append"
      }

      assert :ok = Write.validate_args(args)
    end

    test "rejects missing file_path" do
      args = %{"content" => "Hello"}
      assert {:error, "file_path parameter is required"} = Write.validate_args(args)
    end

    test "rejects empty file_path" do
      args = %{
        "file_path" => "",
        "content" => "Hello"
      }

      assert {:error, "file_path must be a non-empty string"} = Write.validate_args(args)
    end

    test "rejects missing content" do
      args = %{"file_path" => "test.txt"}
      assert {:error, "content parameter is required"} = Write.validate_args(args)
    end

    test "rejects non-string content" do
      args = %{
        "file_path" => "test.txt",
        "content" => 123
      }

      assert {:error, "content must be a string"} = Write.validate_args(args)
    end

    test "rejects invalid mode" do
      args = %{
        "file_path" => "test.txt",
        "content" => "Hello",
        "mode" => "invalid"
      }

      assert {:error, "mode must be 'write' or 'append'"} = Write.validate_args(args)
    end

    test "rejects parent directory references in file_path" do
      args = %{
        "file_path" => "../evil.txt",
        "content" => "Hello"
      }

      assert {:error, "file_path cannot contain parent directory references"} = Write.validate_args(args)
    end
  end

  describe "sandbox_config/0" do
    test "returns appropriate sandbox configuration" do
      config = Write.sandbox_config()

      assert config.timeout == 60_000
      assert config.memory_limit == 100 * 1024 * 1024
      assert config.filesystem_access == :read_write
      assert config.network_access == false
    end
  end

  describe "metadata/0" do
    test "returns valid metadata" do
      metadata = Write.metadata()

      assert metadata.name == "fs_write"
      assert is_binary(metadata.description)
      assert is_map(metadata.parameters)
      assert is_list(metadata.examples)
      assert metadata.version == "1.0.0"

      # Check parameter schema
      params = metadata.parameters
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert params["required"] == ["file_path", "content"]

      # Check mode enum
      mode_prop = params["properties"]["mode"]
      assert mode_prop["enum"] == ["write", "append"]
    end
  end

  describe "error handling" do
    test "handles context without working_dir" do
      args = %{
        "file_path" => "test.txt",
        "content" => "Hello"
      }
      context = %{session_id: "test"}

      assert {:error, "working_dir not provided in context"} = Write.execute(args, context)
    end

    test "handles permission denied gracefully", %{temp_dir: temp_dir, context: context} do
      # Create a read-only directory (Unix-like systems only)
      if match?({:unix, _}, :os.type()) do
        readonly_dir = Path.join(temp_dir, "readonly")
        File.mkdir_p!(readonly_dir)
        File.chmod!(readonly_dir, 0o444)

        args = %{
          "file_path" => "readonly/test.txt",
          "content" => "Hello"
        }

        assert {:error, error_msg} = Write.execute(args, context)
        assert String.contains?(error_msg, "failed to")

        # Restore permissions for cleanup
        File.chmod!(readonly_dir, 0o755)
      end
    end
  end

  describe "size limits" do
    test "rejects content exceeding maximum size", %{context: context} do
      # Create content larger than the 10MB limit
      large_content = String.duplicate("A", 11 * 1024 * 1024)

      args = %{
        "file_path" => "huge.txt",
        "content" => large_content
      }

      assert {:error, error_msg} = Write.execute(args, context)
      assert String.contains?(error_msg, "content too large")
    end

    test "rejects append that would exceed file size limit", %{temp_dir: temp_dir, context: context} do
      # Create a file close to the 10MB limit
      large_content = String.duplicate("A", 9 * 1024 * 1024)
      file_path = Path.join(temp_dir, "large.txt")
      File.write!(file_path, large_content)

      # Try to append content that would exceed the limit
      append_content = String.duplicate("B", 2 * 1024 * 1024)

      args = %{
        "file_path" => "large.txt",
        "content" => append_content,
        "mode" => "append"
      }

      assert {:error, error_msg} = Write.execute(args, context)
      assert String.contains?(error_msg, "resulting file would be too large")
    end
  end
end