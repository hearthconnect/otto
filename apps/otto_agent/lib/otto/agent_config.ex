defmodule Otto.AgentConfig do
  @moduledoc """
  Configuration structure and YAML loading for Otto agents.

  Handles loading agent configurations from YAML files with validation,
  environment variable interpolation, and config merging.
  """

  require Logger

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          tools: [String.t()],
          budgets: map(),
          config: map(),
          metadata: map()
        }

  defstruct [
    :name,
    :description,
    :model,
    :system_prompt,
    tools: [],
    budgets: %{},
    config: %{},
    metadata: %{}
  ]

  @required_fields [:name, :description, :model, :system_prompt, :tools, :budgets]
  @supported_models [
    "claude-3-haiku",
    "claude-3-sonnet",
    "claude-3-opus",
    "gpt-3.5-turbo",
    "gpt-4",
    "gpt-4-turbo"
  ]

  ## Loading Functions

  @doc """
  Loads an agent configuration from a YAML file.
  """
  def load_from_file(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, yaml_data} <- parse_yaml(content),
         {:ok, interpolated} <- interpolate_env_vars(yaml_data),
         config <- struct(__MODULE__, interpolated) do
      {:ok, config}
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, {:unexpected_error, error}}
    end
  catch
    error -> {:error, {:parse_error, error}}
  end

  @doc """
  Loads all agent configurations from a directory.
  Returns a list of {:ok, config} | {:error, path, reason} tuples.
  """
  def load_from_directory(directory_path) do
    if File.exists?(directory_path) and File.dir?(directory_path) do
      directory_path
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".yml"))
      |> Enum.map(fn filename ->
        file_path = Path.join(directory_path, filename)
        case load_from_file(file_path) do
          {:ok, config} -> {:ok, config}
          {:error, reason} -> {:error, file_path, reason}
        end
      end)
    else
      []
    end
  end

  ## Validation

  @doc """
  Validates an agent configuration.
  Returns {:ok, config} or {:error, [error_messages]}.
  """
  def validate(%__MODULE__{} = config) do
    errors = []
             |> validate_required_fields(config)
             |> validate_budgets(config)
             |> validate_tools(config)
             |> validate_model(config)

    case errors do
      [] -> {:ok, config}
      errors -> {:error, errors}
    end
  end

  def validate(invalid), do: {:error, ["Config must be an AgentConfig struct, got: #{inspect(invalid)}"]}

  ## Merging and Serialization

  @doc """
  Merges a base config with override attributes.
  Performs deep merging for nested maps.
  """
  def merge(%__MODULE__{} = base_config, override_attrs) when is_map(override_attrs) do
    # Convert struct to map for easier merging
    base_map = Map.from_struct(base_config)

    # Perform deep merge
    merged_map = deep_merge(base_map, override_attrs)

    # Convert back to struct
    struct(__MODULE__, merged_map)
  end

  @doc """
  Serializes a config to YAML string.
  """
  def to_yaml(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> YamlElixir.write_to_string()
  end

  ## Private Functions

  defp parse_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:yaml_error, reason}}
    end
  end

  defp interpolate_env_vars(data) when is_map(data) do
    {:ok, Map.new(data, fn {key, value} -> {key, interpolate_env_vars_value(value)} end)}
  end

  defp interpolate_env_vars(data), do: {:ok, data}

  defp interpolate_env_vars_value(value) when is_binary(value) do
    # Handle ${VAR} and ${VAR:-default} syntax
    Regex.replace(~r/\$\{([^}:]+)(?::-(.*?))?\}/, value, fn match ->
      case Regex.run(~r/\$\{([^}:]+)(?::-(.*?))?\}/, match) do
        [_, var_name, ""] -> System.get_env(var_name, "")
        [_, var_name, default_value] when default_value != nil -> System.get_env(var_name, default_value)
        [_, var_name] -> System.get_env(var_name, "")
        [_, var_name, nil] -> System.get_env(var_name, "")
      end
    end)
  end

  defp interpolate_env_vars_value(value) when is_number(value) do
    # For numeric values in YAML, try to interpolate as string first
    case to_string(value) do
      string_value ->
        interpolated = interpolate_env_vars_value(string_value)
        case Integer.parse(interpolated) do
          {int_val, ""} -> int_val
          _ ->
            case Float.parse(interpolated) do
              {float_val, ""} -> float_val
              _ -> interpolated
            end
        end
    end
  end

  defp interpolate_env_vars_value(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, interpolate_env_vars_value(v)} end)
  end

  defp interpolate_env_vars_value(value) when is_list(value) do
    Enum.map(value, &interpolate_env_vars_value/1)
  end

  defp interpolate_env_vars_value(value), do: value

  defp validate_required_fields(errors, config) do
    Enum.reduce(@required_fields, errors, fn field, acc ->
      case Map.get(config, field) do
        nil -> ["Missing required field: #{field}" | acc]
        "" -> ["Empty required field: #{field}" | acc]
        [] when field == :tools -> ["Tools list cannot be empty" | acc]
        %{} when field == :budgets and not is_map_key(config, :budgets) ->
          ["Budgets cannot be empty" | acc]
        _ -> acc
      end
    end)
  end

  defp validate_budgets(errors, config) do
    budgets = config.budgets || %{}

    budget_errors = Enum.reduce(budgets, [], fn {key, value}, acc ->
      cond do
        not is_number(value) ->
          ["Budget #{key} must be a number" | acc]
        value <= 0 ->
          ["Budget #{key} must be positive" | acc]
        true ->
          acc
      end
    end)

    budget_errors ++ errors
  end

  defp validate_tools(errors, config) do
    if config.tools && length(config.tools) > 0 do
      # Check if ToolBus is available for validation
      if Code.ensure_loaded?(Otto.ToolBus) and Process.whereis(Otto.ToolBus) do
        available_tools = Otto.ToolBus.list_tools()
        available_tool_names = Enum.map(available_tools, & &1.name)

        tool_errors = Enum.reduce(config.tools, [], fn tool, acc ->
          if tool in available_tool_names do
            acc
          else
            ["Unknown tool: #{tool}" | acc]
          end
        end)

        tool_errors ++ errors
      else
        # ToolBus not available, skip tool validation
        errors
      end
    else
      errors
    end
  end

  defp validate_model(errors, config) do
    if config.model && config.model not in @supported_models do
      Logger.warning("Model #{config.model} is not in the list of supported models: #{inspect(@supported_models)}")
      # Don't add to errors - just warn, as new models might be added
    end
    errors
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, base_value, override_value when is_map(base_value) and is_map(override_value) ->
        deep_merge(base_value, override_value)
      _key, _base_value, override_value ->
        override_value
    end)
  end

  defp deep_merge(_base, override), do: override
end
