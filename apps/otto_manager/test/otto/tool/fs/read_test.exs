defmodule Otto.Tool.FS.ReadTest do
  use ExUnit.Case, async: true

  alias Otto.Tool.FS.Read

  setup do
    # Create a temporary directory for testing
    temp_dir = System.tmp_dir!() |> Path.join("otto_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(temp_dir)

    # Create test files
    test_file = Path.join(temp_dir, "test.txt")
    File.write!(test_file, "Hello, World!\nThis is a test file.")

    subdir = Path.join(temp_dir, "subdir")
    File.mkdir_p!(subdir)
    subfile = Path.join(subdir, "nested.txt")
    File.write!(subfile, "Nested file content")

    context = %{
      working_dir: temp_dir,
      session_id: "test-session"
    }

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir, test_file: test_file, context: context}
  end

  describe "execute/2" do
    test "reads file successfully", %{context: context} do
      args = %{"file_path" => "test.txt"}

      assert {:ok, result} = Read.execute(args, context)
      assert result.content == "Hello, World!\nThis is a test file."
      assert result.size == byte_size(result.content)
      assert result.encoding == "utf8"
      assert String.ends_with?(result.file_path, "test.txt")
    end

    test "reads nested file successfully", %{context: context} do
      args = %{"file_path" => "subdir/nested.txt"}

      assert {:ok, result} = Read.execute(args, context)
      assert result.content == "Nested file content"
      assert result.size == 19
      assert result.encoding == "utf8"
    end

    test "returns error for missing file", %{context: context} do
      args = %{"file_path" => "nonexistent.txt"}

      assert {:error, "file not found"} = Read.execute(args, context)
    end

    test "returns error for directory instead of file", %{context: context} do
      args = %{"file_path" => "subdir"}

      assert {:error, "path is a directory, not a file"} = Read.execute(args, context)
    end

    test "rejects paths outside working directory", %{context: context} do
      args = %{"file_path" => "../../../etc/passwd"}

      assert {:error, "file_path is outside working directory"} = Read.execute(args, context)
    end

    test "rejects absolute paths outside working directory", %{context: context} do
      args = %{"file_path" => "/etc/passwd"}

      assert {:error, "file_path is outside working directory"} = Read.execute(args, context)
    end

    test "handles large files within limit", %{temp_dir: temp_dir, context: context} do
      large_content = String.duplicate("A", 1024)  # 1KB file
      large_file = Path.join(temp_dir, "large.txt")
      File.write!(large_file, large_content)

      args = %{"file_path" => "large.txt"}

      assert {:ok, result} = Read.execute(args, context)
      assert result.size == 1024
      assert result.content == large_content
    end

    test "detects binary encoding", %{temp_dir: temp_dir, context: context} do
      binary_content = <<0, 1, 2, 3, 255>>
      binary_file = Path.join(temp_dir, "binary.dat")
      File.write!(binary_file, binary_content)

      args = %{"file_path" => "binary.dat"}

      assert {:ok, result} = Read.execute(args, context)
      assert result.encoding == "binary"
      assert result.content == binary_content
    end
  end

  describe "validate_args/1" do
    test "validates valid arguments" do
      args = %{"file_path" => "test.txt"}
      assert :ok = Read.validate_args(args)
    end

    test "rejects missing file_path" do
      args = %{}
      assert {:error, "file_path parameter is required"} = Read.validate_args(args)
    end

    test "rejects empty file_path" do
      args = %{"file_path" => ""}
      assert {:error, "file_path must be a non-empty string"} = Read.validate_args(args)
    end

    test "rejects non-string file_path" do
      args = %{"file_path" => 123}
      assert {:error, "file_path must be a non-empty string"} = Read.validate_args(args)
    end
  end

  describe "sandbox_config/0" do
    test "returns appropriate sandbox configuration" do
      config = Read.sandbox_config()

      assert config.timeout == 30_000
      assert config.memory_limit == 50 * 1024 * 1024
      assert config.filesystem_access == :read_only
      assert config.network_access == false
    end
  end

  describe "metadata/0" do
    test "returns valid metadata" do
      metadata = Read.metadata()

      assert metadata.name == "fs_read"
      assert is_binary(metadata.description)
      assert is_map(metadata.parameters)
      assert is_list(metadata.examples)
      assert metadata.version == "1.0.0"

      # Check parameter schema
      params = metadata.parameters
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert params["required"] == ["file_path"]
    end
  end

  describe "error handling" do
    test "handles context without working_dir" do
      args = %{"file_path" => "test.txt"}
      context = %{session_id: "test"}

      assert {:error, "working_dir not provided in context"} = Read.execute(args, context)
    end

    test "handles permission denied gracefully", %{temp_dir: temp_dir, context: context} do
      # Create a file and remove read permissions (Unix-like systems only)
      if match?({:unix, _}, :os.type()) do
        restricted_file = Path.join(temp_dir, "restricted.txt")
        File.write!(restricted_file, "content")
        File.chmod!(restricted_file, 0o000)

        args = %{"file_path" => "restricted.txt"}

        assert {:error, "permission denied"} = Read.execute(args, context)

        # Restore permissions for cleanup
        File.chmod!(restricted_file, 0o644)
      end
    end
  end
end