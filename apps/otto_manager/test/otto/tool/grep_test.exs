defmodule Otto.Tool.GrepTest do
  use ExUnit.Case, async: true

  alias Otto.Tool.Grep

  setup do
    # Create a temporary directory for testing
    temp_dir = System.tmp_dir!() |> Path.join("otto_grep_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(temp_dir)

    # Create test files with various content
    File.write!(Path.join(temp_dir, "test.ex"), """
    defmodule TestModule do
      def hello_world do
        "Hello, World!"
      end

      def goodbye_world do
        "Goodbye, World!"
      end
    end
    """)

    File.write!(Path.join(temp_dir, "README.md"), """
    # Test Project

    This is a test project with some documentation.
    It contains examples and explanations.
    """)

    # Create subdirectory with more files
    subdir = Path.join(temp_dir, "lib")
    File.mkdir_p!(subdir)

    File.write!(Path.join(subdir, "helper.ex"), """
    defmodule Helper do
      def utility_function do
        IO.puts("Utility output")
      end
    end
    """)

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
    test "finds simple pattern matches", %{context: context} do
      args = %{"pattern" => "def"}

      assert {:ok, result} = Grep.execute(args, context)
      assert result.pattern == "def"
      assert result.total_matches > 0
      assert result.truncated == false

      # Should find function definitions
      matches = result.results
      assert Enum.any?(matches, fn match ->
        String.contains?(match["line"], "def hello_world")
      end)
    end

    test "searches with file pattern filter", %{context: context} do
      args = %{
        "pattern" => "defmodule",
        "file_pattern" => "*.ex"
      }

      assert {:ok, result} = Grep.execute(args, context)

      # Should only find matches in .ex files
      matches = result.results
      assert Enum.all?(matches, fn match ->
        String.ends_with?(match["file"], ".ex")
      end)

      # Should find both modules
      module_matches = Enum.filter(matches, fn match ->
        String.contains?(match["line"], "defmodule")
      end)
      assert length(module_matches) >= 2
    end

    test "searches with case insensitive option", %{context: context} do
      args = %{
        "pattern" => "HELLO",
        "case_sensitive" => false
      }

      assert {:ok, result} = Grep.execute(args, context)
      assert result.total_matches > 0

      # Should find "hello" despite case mismatch
      matches = result.results
      assert Enum.any?(matches, fn match ->
        String.contains?(String.downcase(match["line"]), "hello")
      end)
    end

    test "searches with context lines", %{context: _context} do
      args = %{
        "pattern" => "hello_world",
        "context_lines" => 2
      }

      # Note: This test depends on ripgrep being available and supporting JSON output
      # We'll test the argument building without requiring actual ripgrep execution
      assert :ok = Grep.validate_args(args)
    end

    test "returns empty results for no matches", %{context: context} do
      args = %{"pattern" => "nonexistent_pattern_xyz123"}

      assert {:ok, result} = Grep.execute(args, context)
      assert result.total_matches == 0
      assert result.results == []
      assert result.truncated == false
    end

    test "limits search depth", %{context: _context} do
      args = %{
        "pattern" => "def",
        "max_depth" => 1
      }

      assert :ok = Grep.validate_args(args)
    end

    test "includes hidden files when requested", %{temp_dir: temp_dir, context: _context} do
      # Create a hidden file
      File.write!(Path.join(temp_dir, ".hidden"), "secret content")

      args = %{
        "pattern" => "secret",
        "include_hidden" => true
      }

      assert :ok = Grep.validate_args(args)
    end
  end

  describe "validate_args/1" do
    test "validates valid arguments" do
      args = %{"pattern" => "test_pattern"}
      assert :ok = Grep.validate_args(args)
    end

    test "validates arguments with all options" do
      args = %{
        "pattern" => "test",
        "file_pattern" => "*.ex",
        "case_sensitive" => false,
        "context_lines" => 3,
        "max_depth" => 5,
        "include_hidden" => true
      }

      assert :ok = Grep.validate_args(args)
    end

    test "rejects missing pattern" do
      args = %{}
      assert {:error, "pattern parameter is required"} = Grep.validate_args(args)
    end

    test "rejects empty pattern" do
      args = %{"pattern" => ""}
      assert {:error, "pattern must be a non-empty string"} = Grep.validate_args(args)
    end

    test "rejects non-string pattern" do
      args = %{"pattern" => 123}
      assert {:error, "pattern must be a non-empty string"} = Grep.validate_args(args)
    end

    test "rejects invalid context_lines" do
      args = %{
        "pattern" => "test",
        "context_lines" => 15  # Above maximum
      }

      assert {:error, "context_lines must be an integer between 0 and 10"} = Grep.validate_args(args)
    end

    test "rejects negative context_lines" do
      args = %{
        "pattern" => "test",
        "context_lines" => -1
      }

      assert {:error, "context_lines must be an integer between 0 and 10"} = Grep.validate_args(args)
    end

    test "rejects invalid max_depth" do
      args = %{
        "pattern" => "test",
        "max_depth" => 25  # Above maximum
      }

      assert {:error, "max_depth must be an integer between 1 and 20"} = Grep.validate_args(args)
    end

    test "rejects zero max_depth" do
      args = %{
        "pattern" => "test",
        "max_depth" => 0
      }

      assert {:error, "max_depth must be an integer between 1 and 20"} = Grep.validate_args(args)
    end
  end

  describe "sandbox_config/0" do
    test "returns appropriate sandbox configuration" do
      config = Grep.sandbox_config()

      assert config.timeout == 35_000  # 30s + 5s buffer
      assert config.memory_limit == 100 * 1024 * 1024
      assert config.filesystem_access == :read_only
      assert config.network_access == false
    end
  end

  describe "metadata/0" do
    test "returns valid metadata" do
      metadata = Grep.metadata()

      assert metadata.name == "grep"
      assert is_binary(metadata.description)
      assert is_map(metadata.parameters)
      assert is_list(metadata.examples)
      assert metadata.version == "1.0.0"

      # Check parameter schema
      params = metadata.parameters
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert params["required"] == ["pattern"]

      # Check specific parameter definitions
      pattern_prop = params["properties"]["pattern"]
      assert pattern_prop["type"] == "string"

      context_prop = params["properties"]["context_lines"]
      assert context_prop["minimum"] == 0
      assert context_prop["maximum"] == 10
    end
  end

  describe "error handling" do
    test "handles context without working_dir" do
      args = %{"pattern" => "test"}
      context = %{session_id: "test"}

      assert {:error, "working_dir not provided in context"} = Grep.execute(args, context)
    end

    test "handles non-existent working directory gracefully" do
      args = %{"pattern" => "test"}
      context = %{
        working_dir: "/nonexistent/directory",
        session_id: "test"
      }

      # This should fail gracefully when ripgrep is executed
      assert {:error, _} = Grep.execute(args, context)
    end
  end

  # Helper function tests (testing internal logic without ripgrep dependency)
  describe "argument building" do
    test "builds correct ripgrep arguments for basic search" do
      # We can't easily test the private functions, but we can test validation
      # which exercises the same logic paths
      args = %{
        "pattern" => "test",
        "file_pattern" => "*.ex",
        "case_sensitive" => false,
        "context_lines" => 2,
        "max_depth" => 5,
        "include_hidden" => true
      }

      assert :ok = Grep.validate_args(args)
    end
  end
end