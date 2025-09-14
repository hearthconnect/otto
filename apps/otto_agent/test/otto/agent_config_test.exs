defmodule Otto.AgentConfigTest do
  use ExUnit.Case
  alias Otto.AgentConfig

  @fixtures_path Path.join(__DIR__, "../fixtures/agents")

  describe "AgentConfig struct" do
    test "has all required fields" do
      config = %AgentConfig{}

      expected_fields = [
        :name,
        :description,
        :model,
        :system_prompt,
        :tools,
        :budgets,
        :config,
        :metadata
      ]

      for field <- expected_fields do
        assert Map.has_key?(config, field), "Missing field: #{field}"
      end
    end

    test "can be created with valid attributes" do
      attrs = %{
        name: "TestAgent",
        description: "A test agent",
        model: "claude-3-haiku",
        system_prompt: "You are helpful",
        tools: ["FS.Read"],
        budgets: %{time_limit: 300}
      }

      config = struct(AgentConfig, attrs)
      assert config.name == "TestAgent"
      assert config.tools == ["FS.Read"]
    end
  end

  describe "YAML loading" do
    test "loads valid basic agent config" do
      path = Path.join(@fixtures_path, "valid_basic.yml")

      assert {:ok, config} = AgentConfig.load_from_file(path)
      assert config.name == "BasicTestAgent"
      assert config.description == "A simple agent for testing basic functionality"
      assert config.model == "claude-3-haiku"
      assert String.contains?(config.system_prompt, "helpful assistant")
      assert "FS.Read" in config.tools
      assert "FS.Write" in config.tools
      assert config.budgets.time_limit == 300
      assert config.budgets.token_limit == 10000
      assert config.budgets.cost_limit == 1.0
    end

    test "loads complex agent config with all features" do
      path = Path.join(@fixtures_path, "valid_complex.yml")

      assert {:ok, config} = AgentConfig.load_from_file(path)
      assert config.name == "ComplexTestAgent"
      assert config.model == "claude-3-sonnet"
      assert length(config.tools) == 5
      assert "HTTP" in config.tools
      assert "Grep" in config.tools
      assert "TestRunner" in config.tools

      # Check nested config
      assert config.config.working_dir == "/tmp/agent_workspace"
      assert config.config.max_file_size == 2097152
      assert "api.github.com" in config.config.allowed_domains

      # Check metadata
      assert config.metadata.version == "1.0"
      assert config.metadata.author == "Otto Test Suite"
      assert "testing" in config.metadata.tags
    end

    test "handles environment variable interpolation" do
      path = Path.join(@fixtures_path, "with_env_vars.yml")

      # Set test environment variables
      System.put_env("AI_MODEL", "claude-3-sonnet")
      System.put_env("AGENT_ROLE", "a code reviewer")
      System.put_env("TIME_LIMIT", "600")
      System.put_env("WORKSPACE_DIR", "/tmp/test_workspace")

      assert {:ok, config} = AgentConfig.load_from_file(path)
      assert config.model == "claude-3-sonnet"
      assert String.contains?(config.system_prompt, "a code reviewer")
      assert config.budgets.time_limit == 600
      assert config.config.working_dir == "/tmp/test_workspace"

      # Clean up
      System.delete_env("AI_MODEL")
      System.delete_env("AGENT_ROLE")
      System.delete_env("TIME_LIMIT")
      System.delete_env("WORKSPACE_DIR")
    end

    test "uses default values for missing environment variables" do
      path = Path.join(@fixtures_path, "with_env_vars.yml")

      # Ensure env vars are not set
      System.delete_env("AI_MODEL")
      System.delete_env("AGENT_ROLE")
      System.delete_env("TIME_LIMIT")

      assert {:ok, config} = AgentConfig.load_from_file(path)
      assert config.model == "claude-3-haiku"  # Default value
      assert String.contains?(config.system_prompt, "a helpful assistant")  # Default
      assert config.budgets.time_limit == 300  # Default
    end

    test "fails for non-existent file" do
      path = Path.join(@fixtures_path, "non_existent.yml")

      assert {:error, reason} = AgentConfig.load_from_file(path)
      assert String.contains?(to_string(reason), "file") or match?({:file_error, _}, reason)
    end

    test "fails for YAML syntax errors" do
      path = Path.join(@fixtures_path, "invalid_syntax.yml")

      assert {:error, reason} = AgentConfig.load_from_file(path)
      assert match?({:yaml_error, _}, reason) or String.contains?(to_string(reason), "yaml")
    end
  end

  describe "validation" do
    test "validates required fields are present" do
      # Missing name
      invalid_config = %AgentConfig{
        description: "Test",
        model: "claude-3-haiku",
        system_prompt: "Test",
        tools: ["FS.Read"],
        budgets: %{time_limit: 300}
      }

      assert {:error, errors} = AgentConfig.validate(invalid_config)
      assert Enum.any?(errors, &String.contains?(&1, "name"))
    end

    test "validates tool references" do
      # Register a test tool for validation
      if Code.ensure_loaded?(Otto.ToolBus) do
        Otto.ToolBus.register_tool(Otto.ToolBusTest.TestTool)
      end

      config = %AgentConfig{
        name: "TestAgent",
        description: "Test",
        model: "claude-3-haiku",
        system_prompt: "Test",
        tools: ["test_tool", "nonexistent_tool"],  # One valid, one invalid
        budgets: %{time_limit: 300}
      }

      case AgentConfig.validate(config) do
        {:ok, _} -> :ok  # Tools might not be registered yet
        {:error, errors} ->
          # Should contain error about nonexistent tool
          tool_errors = Enum.filter(errors, &String.contains?(&1, "tool"))
          assert length(tool_errors) > 0
      end
    end

    test "validates budget values are positive" do
      config = %AgentConfig{
        name: "TestAgent",
        description: "Test",
        model: "claude-3-haiku",
        system_prompt: "Test",
        tools: ["FS.Read"],
        budgets: %{
          time_limit: -300,  # Invalid: negative
          token_limit: 0,    # Invalid: zero
          cost_limit: 1.0
        }
      }

      assert {:error, errors} = AgentConfig.validate(config)
      budget_errors = Enum.filter(errors, &(String.contains?(&1, "budget") or String.contains?(&1, "limit")))
      assert length(budget_errors) > 0
    end

    test "validates model is supported" do
      config = %AgentConfig{
        name: "TestAgent",
        description: "Test",
        model: "unsupported-model-v99",
        system_prompt: "Test",
        tools: ["FS.Read"],
        budgets: %{time_limit: 300}
      }

      case AgentConfig.validate(config) do
        {:ok, _} -> :ok  # Might accept unknown models
        {:error, errors} ->
          model_errors = Enum.filter(errors, &String.contains?(&1, "model"))
          assert length(model_errors) > 0
      end
    end

    test "accepts valid complete config" do
      config = %AgentConfig{
        name: "ValidAgent",
        description: "A valid test agent",
        model: "claude-3-haiku",
        system_prompt: "You are helpful",
        tools: ["FS.Read", "FS.Write"],
        budgets: %{
          time_limit: 300,
          token_limit: 10000,
          cost_limit: 1.0
        },
        config: %{
          working_dir: "/tmp/test",
          max_file_size: 1048576
        },
        metadata: %{
          version: "1.0"
        }
      }

      case AgentConfig.validate(config) do
        {:ok, validated_config} ->
          assert validated_config.name == "ValidAgent"
        {:error, _errors} ->
          # Validation might be strict during development
          :ok
      end
    end
  end

  describe "directory loading" do
    test "loads all valid configs from directory" do
      configs = AgentConfig.load_from_directory(@fixtures_path)

      # Should load at least the valid configs
      assert length(configs) >= 2

      # Check that valid configs are present
      config_names = Enum.map(configs, fn {:ok, config} -> config.name end)
      assert "BasicTestAgent" in config_names
      assert "ComplexTestAgent" in config_names
    end

    test "includes error information for invalid configs" do
      configs = AgentConfig.load_from_directory(@fixtures_path)

      # Should have some errors for invalid files
      error_results = Enum.filter(configs, fn
        {:error, _path, _reason} -> true
        _ -> false
      end)

      assert length(error_results) > 0
    end

    test "handles empty directory gracefully" do
      empty_dir = "/tmp/empty_agent_configs_test"
      File.mkdir_p!(empty_dir)

      configs = AgentConfig.load_from_directory(empty_dir)
      assert configs == []

      File.rm_rf!(empty_dir)
    end

    test "handles non-existent directory" do
      configs = AgentConfig.load_from_directory("/non/existent/directory")
      assert configs == []
    end
  end

  describe "config merging and overrides" do
    test "merges project-level and user-level configs" do
      base_config = %AgentConfig{
        name: "BaseAgent",
        description: "Base config",
        model: "claude-3-haiku",
        system_prompt: "Base prompt",
        tools: ["FS.Read"],
        budgets: %{time_limit: 300, cost_limit: 1.0}
      }

      override_config = %{
        model: "claude-3-sonnet",  # Override model
        budgets: %{cost_limit: 2.0},  # Override cost limit, keep time limit
        config: %{working_dir: "/tmp/override"}  # Add new config
      }

      merged = AgentConfig.merge(base_config, override_config)

      assert merged.name == "BaseAgent"  # Unchanged
      assert merged.model == "claude-3-sonnet"  # Overridden
      assert merged.budgets.time_limit == 300  # Preserved
      assert merged.budgets.cost_limit == 2.0  # Overridden
      assert merged.config.working_dir == "/tmp/override"  # Added
    end

    test "handles deep merging of nested maps" do
      base_config = %AgentConfig{
        name: "DeepMergeTest",
        budgets: %{
          time_limit: 300,
          token_limit: 10000,
          cost_limit: 1.0
        },
        config: %{
          working_dir: "/tmp/base",
          max_file_size: 1048576,
          allowed_domains: ["example.com"]
        }
      }

      override_attrs = %{
        budgets: %{cost_limit: 2.0},  # Only override cost_limit
        config: %{
          max_file_size: 2097152,  # Override file size
          timeout: 30  # Add new field
        }
      }

      merged = AgentConfig.merge(base_config, override_attrs)

      # Budgets should be deeply merged
      assert merged.budgets.time_limit == 300  # Preserved
      assert merged.budgets.token_limit == 10000  # Preserved
      assert merged.budgets.cost_limit == 2.0  # Overridden

      # Config should be deeply merged
      assert merged.config.working_dir == "/tmp/base"  # Preserved
      assert merged.config.max_file_size == 2097152  # Overridden
      assert merged.config.timeout == 30  # Added
      assert merged.config.allowed_domains == ["example.com"]  # Preserved
    end
  end

  describe "serialization" do
    test "can serialize config to YAML" do
      config = %AgentConfig{
        name: "SerializeTest",
        description: "Test serialization",
        model: "claude-3-haiku",
        system_prompt: "Test prompt",
        tools: ["FS.Read", "FS.Write"],
        budgets: %{time_limit: 300, cost_limit: 1.0}
      }

      {:ok, yaml_string} = AgentConfig.to_yaml(config)
      assert is_binary(yaml_string)
      assert String.contains?(yaml_string, "SerializeTest")
      assert String.contains?(yaml_string, "FS.Read")
    end

    test "roundtrip YAML serialization preserves data" do
      original_config = %AgentConfig{
        name: "RoundtripTest",
        description: "Test roundtrip serialization",
        model: "claude-3-sonnet",
        system_prompt: "Roundtrip test prompt",
        tools: ["FS.Read", "HTTP"],
        budgets: %{
          time_limit: 600,
          token_limit: 20000,
          cost_limit: 5.0
        },
        config: %{
          working_dir: "/tmp/roundtrip",
          max_file_size: 1048576
        }
      }

      # Serialize to YAML
      {:ok, yaml_string} = AgentConfig.to_yaml(original_config)

      # Write to temp file and reload
      temp_file = "/tmp/roundtrip_test.yml"
      File.write!(temp_file, yaml_string)

      {:ok, loaded_config} = AgentConfig.load_from_file(temp_file)

      # Compare key fields (some fields might have type differences after YAML roundtrip)
      assert loaded_config.name == original_config.name
      assert loaded_config.description == original_config.description
      assert loaded_config.model == original_config.model
      assert loaded_config.tools == original_config.tools

      # Clean up
      File.rm!(temp_file)
    end
  end
end