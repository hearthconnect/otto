defmodule Otto.Agent.Config do
  @moduledoc """
  Agent configuration structure with YAML loading and validation.

  Supports loading agent configurations from YAML files and validating
  them against a schema using NimbleOptions.
  """

  alias __MODULE__

  defstruct [
    :name,
    :model,
    :system_prompt,
    :working_dir,
    budgets: %{}
  ]

  @type budget :: %{
    time_seconds: pos_integer(),
    max_tokens: pos_integer(),
    max_cost_dollars: float()
  }

  @type t :: %Config{
    name: String.t(),
    model: String.t(),
    system_prompt: String.t(),
    working_dir: String.t(),
    budgets: budget()
  }

  @config_schema [
    name: [
      type: :string,
      required: true,
      doc: "Name of the agent"
    ],
    model: [
      type: :string,
      default: "gpt-3.5-turbo",
      doc: "LLM model to use for the agent (e.g., gpt-3.5-turbo, gpt-4)"
    ],
    system_prompt: [
      type: :string,
      required: true,
      doc: "System prompt for the agent"
    ],
    working_dir: [
      type: :string,
      required: true,
      doc: "Working directory for the agent (sandboxed file operations)"
    ],
    budgets: [
      type: :keyword_list,
      default: [],
      doc: "Budget constraints for the agent",
      keys: [
        time_seconds: [type: :pos_integer, doc: "Maximum execution time in seconds"],
        max_tokens: [type: :pos_integer, doc: "Maximum tokens to consume"],
        max_cost_dollars: [type: :float, doc: "Maximum cost in dollars"]
      ]
    ]
  ]

  @doc """
  Loads an agent configuration from a YAML file.

  ## Examples

      iex> Otto.Agent.Config.load_from_file("/path/to/agent.yaml")
      {:ok, %Otto.Agent.Config{name: "test-agent", ...}}

      iex> Otto.Agent.Config.load_from_file("/nonexistent.yaml")
      {:error, :file_not_found}
  """
  @spec load_from_file(String.t()) :: {:ok, t()} | {:error, term()}
  def load_from_file(file_path) do
    with {:ok, yaml_content} <- YamlElixir.read_from_file(file_path),
         {:ok, validated_config} <- validate_config(yaml_content) do
      config = struct(Config, validated_config)
      {:ok, config}
    else
      {:error, %YamlElixir.FileNotFoundError{}} ->
        {:error, :file_not_found}

      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Loads an agent configuration from a YAML string.

  ## Examples

      iex> yaml = "name: test\\nsystem_prompt: Hello\\nworking_dir: /tmp"
      iex> Otto.Agent.Config.load_from_string(yaml)
      {:ok, %Otto.Agent.Config{name: "test", ...}}
  """
  @spec load_from_string(String.t()) :: {:ok, t()} | {:error, term()}
  def load_from_string(yaml_string) do
    with {:ok, yaml_content} <- YamlElixir.read_from_string(yaml_string),
         {:ok, validated_config} <- validate_config(yaml_content) do
      config = struct(Config, validated_config)
      {:ok, config}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates a raw configuration map against the schema.

  Returns {:ok, validated_config} or {:error, validation_errors}.
  """
  @spec validate_config(map()) :: {:ok, keyword()} | {:error, term()}
  def validate_config(raw_config) when is_map(raw_config) do
    # Convert string keys to atoms and to keyword list for validation
    config_list =
      raw_config
      |> Enum.map(fn {k, v} ->
        {atom_key, converted_value} = convert_config_entry(k, v)
        {atom_key, converted_value}
      end)

    case NimbleOptions.validate(config_list, @config_schema) do
      {:ok, validated} ->
        # Convert budgets from keyword list to map if needed
        budgets =
          case Keyword.get(validated, :budgets, []) do
            budgets when is_list(budgets) -> Enum.into(budgets, %{})
            budgets when is_map(budgets) -> budgets
          end

        validated_config =
          validated
          |> Keyword.put(:budgets, budgets)

        {:ok, validated_config}

      {:error, error} ->
        {:error, {:validation_failed, error}}
    end
  rescue
    ArgumentError ->
      {:error, :invalid_config_keys}
  end

  @doc """
  Returns the configuration schema for documentation purposes.
  """
  @spec schema() :: keyword()
  def schema, do: @config_schema

  @doc """
  Checks if a working directory path is valid and accessible.

  ## Examples

      iex> Otto.Agent.Config.validate_working_dir("/tmp")
      {:ok, "/tmp"}

      iex> Otto.Agent.Config.validate_working_dir("/nonexistent")
      {:error, :working_dir_not_accessible}
  """
  @spec validate_working_dir(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate_working_dir(working_dir) do
    expanded_path = Path.expand(working_dir)

    cond do
      not File.exists?(expanded_path) ->
        {:error, :working_dir_not_found}

      not File.dir?(expanded_path) ->
        {:error, :working_dir_not_directory}

      File.stat!(expanded_path).access not in [:read_write, :read] ->
        {:error, :working_dir_not_accessible}

      true ->
        {:ok, expanded_path}
    end
  rescue
    File.Error ->
      {:error, :working_dir_not_accessible}
  end

  @doc """
  Validates that a file path is within the allowed working directory.

  ## Examples

      iex> config = %Otto.Agent.Config{working_dir: "/tmp"}
      iex> Otto.Agent.Config.path_within_working_dir?(config, "/tmp/file.txt")
      true

      iex> Otto.Agent.Config.path_within_working_dir?(config, "/etc/passwd")
      false
  """
  @spec path_within_working_dir?(t(), String.t()) :: boolean()
  def path_within_working_dir?(%Config{working_dir: working_dir}, file_path) do
    expanded_working_dir = Path.expand(working_dir)
    expanded_file_path = Path.expand(file_path, working_dir)

    String.starts_with?(expanded_file_path, expanded_working_dir)
  end

  # Private helper functions

  defp convert_config_entry(key, value) when is_binary(key) do
    atom_key = String.to_existing_atom(key)
    converted_value = convert_config_value(atom_key, value)
    {atom_key, converted_value}
  end

  defp convert_config_value(:budgets, budgets) when is_map(budgets) do
    # Convert map to keyword list for NimbleOptions validation
    budgets
    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp convert_config_value(_key, value), do: value
end