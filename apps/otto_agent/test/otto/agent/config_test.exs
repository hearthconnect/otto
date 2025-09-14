defmodule Otto.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Otto.Agent.Config

  @valid_yaml """
  name: test-agent
  system_prompt: "You are a helpful test agent"
  tools:
    - fs_read
    - fs_write
    - grep
  working_dir: "/tmp/test"
  budgets:
    time_seconds: 300
    max_tokens: 10000
    max_cost_dollars: 5.0
  """

  @minimal_yaml """
  name: minimal-agent
  system_prompt: "Minimal agent"
  working_dir: "/tmp/minimal"
  """

  describe "load_from_string/1" do
    test "loads valid configuration successfully" do
      assert {:ok, config} = Config.load_from_string(@valid_yaml)

      assert config.name == "test-agent"
      assert config.system_prompt == "You are a helpful test agent"
      assert config.tools == ["fs_read", "fs_write", "grep"]
      assert config.working_dir == "/tmp/test"
      assert config.budgets.time_seconds == 300
      assert config.budgets.max_tokens == 10000
      assert config.budgets.max_cost_dollars == 5.0
    end

    test "loads minimal configuration with defaults" do
      assert {:ok, config} = Config.load_from_string(@minimal_yaml)

      assert config.name == "minimal-agent"
      assert config.system_prompt == "Minimal agent"
      assert config.tools == []
      assert config.working_dir == "/tmp/minimal"
      assert config.budgets == %{}
    end

    test "returns error for invalid YAML" do
      invalid_yaml = "name: test\n  invalid: yaml: structure"

      assert {:error, _reason} = Config.load_from_string(invalid_yaml)
    end

    test "returns error for missing required fields" do
      missing_name = """
      system_prompt: "Test"
      working_dir: "/tmp"
      """

      assert {:error, {:validation_failed, _}} = Config.load_from_string(missing_name)
    end

    test "validates budget constraints" do
      yaml_with_budgets = """
      name: budget-test
      system_prompt: "Test"
      working_dir: "/tmp"
      budgets:
        time_seconds: -1
      """

      assert {:error, {:validation_failed, _}} = Config.load_from_string(yaml_with_budgets)
    end
  end

  describe "load_from_file/1" do
    setup do
      temp_dir = System.tmp_dir!()
      config_file = Path.join(temp_dir, "test_agent_config.yaml")

      on_exit(fn ->
        File.rm(config_file)
      end)

      {:ok, config_file: config_file}
    end

    test "loads configuration from file", %{config_file: config_file} do
      File.write!(config_file, @valid_yaml)

      assert {:ok, config} = Config.load_from_file(config_file)
      assert config.name == "test-agent"
    end

    test "returns error for nonexistent file" do
      assert {:error, :file_not_found} = Config.load_from_file("/nonexistent/config.yaml")
    end

    test "returns error for invalid file content", %{config_file: config_file} do
      File.write!(config_file, "invalid: yaml: content")

      assert {:error, _reason} = Config.load_from_file(config_file)
    end
  end

  describe "validate_config/1" do
    test "validates correct configuration" do
      config = %{
        "name" => "test",
        "system_prompt" => "Test prompt",
        "working_dir" => "/tmp",
        "tools" => ["fs_read"],
        "budgets" => %{"time_seconds" => 300}
      }

      assert {:ok, validated} = Config.validate_config(config)
      assert Keyword.get(validated, :name) == "test"
      assert is_map(Keyword.get(validated, :budgets))
    end

    test "returns error for invalid keys" do
      config = %{
        "invalid_key" => "value",
        "name" => "test",
        "system_prompt" => "Test",
        "working_dir" => "/tmp"
      }

      assert {:error, {:validation_failed, _}} = Config.validate_config(config)
    end

    test "validates budget structure" do
      config = %{
        "name" => "test",
        "system_prompt" => "Test",
        "working_dir" => "/tmp",
        "budgets" => %{
          "time_seconds" => 300,
          "max_tokens" => 1000,
          "max_cost_dollars" => 10.0
        }
      }

      assert {:ok, validated} = Config.validate_config(config)
      budgets = Keyword.get(validated, :budgets)

      assert budgets.time_seconds == 300
      assert budgets.max_tokens == 1000
      assert budgets.max_cost_dollars == 10.0
    end
  end

  describe "validate_working_dir/1" do
    test "validates existing directory" do
      temp_dir = System.tmp_dir!()
      assert {:ok, expanded_path} = Config.validate_working_dir(temp_dir)
      assert String.starts_with?(expanded_path, "/")
    end

    test "returns error for nonexistent directory" do
      assert {:error, :working_dir_not_found} = Config.validate_working_dir("/nonexistent/path")
    end

    test "returns error for file instead of directory" do
      temp_file = Path.join(System.tmp_dir!(), "test_file")
      File.write!(temp_file, "content")

      assert {:error, :working_dir_not_directory} = Config.validate_working_dir(temp_file)

      File.rm!(temp_file)
    end
  end

  describe "path_within_working_dir?/2" do
    setup do
      config = %Config{working_dir: "/tmp/test"}
      {:ok, config: config}
    end

    test "returns true for paths within working directory", %{config: config} do
      assert Config.path_within_working_dir?(config, "/tmp/test/file.txt")
      assert Config.path_within_working_dir?(config, "/tmp/test/subdir/file.txt")
    end

    test "returns false for paths outside working directory", %{config: config} do
      refute Config.path_within_working_dir?(config, "/etc/passwd")
      refute Config.path_within_working_dir?(config, "/tmp/other/file.txt")
      refute Config.path_within_working_dir?(config, "/tmp/test/../../../etc/passwd")
    end

    test "handles relative paths correctly", %{config: config} do
      assert Config.path_within_working_dir?(config, "file.txt")
      assert Config.path_within_working_dir?(config, "subdir/file.txt")
      refute Config.path_within_working_dir?(config, "../outside.txt")
    end
  end

  describe "schema/0" do
    test "returns valid NimbleOptions schema" do
      schema = Config.schema()
      assert is_list(schema)

      # Check that required fields are present
      assert Keyword.has_key?(schema, :name)
      assert Keyword.has_key?(schema, :system_prompt)
      assert Keyword.has_key?(schema, :working_dir)
      assert Keyword.has_key?(schema, :tools)
      assert Keyword.has_key?(schema, :budgets)
    end
  end
end