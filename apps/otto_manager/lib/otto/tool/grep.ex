defmodule Otto.Tool.Grep do
  @moduledoc """
  Tool for searching file contents using ripgrep within the agent's working directory.

  This tool provides powerful text search capabilities with regex support,
  file filtering, and context options. All searches are confined to the
  agent's working directory for security.
  """

  use Otto.Tool
  require Logger

  @max_results 1000
  @timeout 30_000

  @impl Otto.Tool
  def execute(args, context) do
    with :ok <- validate_args(args),
         {:ok, working_dir} <- get_working_dir(context),
         {:ok, search_params} <- build_search_params(args, working_dir),
         {:ok, results} <- execute_ripgrep(search_params, context) do

      Logger.info("Grep search completed",
        session_id: Map.get(context, :session_id),
        pattern: Map.get(args, "pattern"),
        result_count: length(results),
        working_dir: working_dir
      )

      {:ok, %{
        pattern: Map.get(args, "pattern"),
        working_dir: working_dir,
        results: results,
        total_matches: length(results),
        truncated: length(results) >= @max_results
      }}
    else
      {:error, reason} ->
        Logger.warning("Grep search failed",
          session_id: Map.get(context, :session_id),
          pattern: Map.get(args, "pattern"),
          reason: reason
        )
        {:error, reason}
    end
  end

  @impl Otto.Tool
  def validate_args(args) do
    with {:ok, _} <- validate_pattern(args),
         :ok <- validate_options(args) do
      :ok
    end
  end

  @impl Otto.Tool
  def sandbox_config do
    %{
      timeout: @timeout + 5_000,  # Add buffer for cleanup
      memory_limit: 100 * 1024 * 1024,  # 100 MB
      filesystem_access: :read_only,
      network_access: false
    }
  end

  @impl Otto.Tool
  def metadata do
    %{
      name: "grep",
      description: "Search for patterns in files using ripgrep within the working directory",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regular expression pattern to search for"
          },
          "file_pattern" => %{
            "type" => "string",
            "description" => "Glob pattern to filter files (e.g., '*.ex', '**/*.js')",
            "default" => "*"
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" => "Whether the search should be case-sensitive",
            "default" => true
          },
          "context_lines" => %{
            "type" => "integer",
            "description" => "Number of context lines to show around matches",
            "minimum" => 0,
            "maximum" => 10,
            "default" => 0
          },
          "max_depth" => %{
            "type" => "integer",
            "description" => "Maximum directory depth to search",
            "minimum" => 1,
            "maximum" => 20,
            "default" => 10
          },
          "include_hidden" => %{
            "type" => "boolean",
            "description" => "Include hidden files and directories in search",
            "default" => false
          }
        },
        "required" => ["pattern"]
      },
      examples: [
        %{
          "description" => "Search for function definitions in Elixir files",
          "args" => %{
            "pattern" => "def\\s+\\w+",
            "file_pattern" => "**/*.ex",
            "context_lines" => 2
          },
          "result" => %{
            "pattern" => "def\\s+\\w+",
            "working_dir" => "/agent/working/dir",
            "results" => [
              %{
                "file" => "lib/my_module.ex",
                "line_number" => 10,
                "line" => "  def my_function(arg) do",
                "context_before" => ["", "  @doc \"Example function\""],
                "context_after" => ["    arg + 1", "  end"]
              }
            ],
            "total_matches" => 1,
            "truncated" => false
          }
        }
      ],
      version: "1.0.0"
    }
  end

  # Private helper functions

  defp validate_pattern(args) do
    case Map.get(args, "pattern") do
      nil ->
        {:error, "pattern parameter is required"}

      pattern when is_binary(pattern) and byte_size(pattern) > 0 ->
        {:ok, pattern}

      _ ->
        {:error, "pattern must be a non-empty string"}
    end
  end

  defp validate_options(args) do
    with :ok <- validate_context_lines(args),
         :ok <- validate_max_depth(args) do
      :ok
    end
  end

  defp validate_context_lines(args) do
    case Map.get(args, "context_lines", 0) do
      lines when is_integer(lines) and lines >= 0 and lines <= 10 ->
        :ok

      _ ->
        {:error, "context_lines must be an integer between 0 and 10"}
    end
  end

  defp validate_max_depth(args) do
    case Map.get(args, "max_depth", 10) do
      depth when is_integer(depth) and depth >= 1 and depth <= 20 ->
        :ok

      _ ->
        {:error, "max_depth must be an integer between 1 and 20"}
    end
  end

  defp get_working_dir(context) do
    case Map.get(context, :working_dir) do
      working_dir when is_binary(working_dir) ->
        {:ok, working_dir}
      _ ->
        {:error, "working_dir not provided in context"}
    end
  end

  defp build_search_params(args, working_dir) do
    params = %{
      pattern: Map.get(args, "pattern"),
      working_dir: working_dir,
      file_pattern: Map.get(args, "file_pattern", "*"),
      case_sensitive: Map.get(args, "case_sensitive", true),
      context_lines: Map.get(args, "context_lines", 0),
      max_depth: Map.get(args, "max_depth", 10),
      include_hidden: Map.get(args, "include_hidden", false)
    }

    {:ok, params}
  end

  defp execute_ripgrep(params, context) do
    cmd_args = build_ripgrep_args(params)

    try do
      case System.cmd("rg", cmd_args, [
        cd: params.working_dir,
        stderr_to_stdout: true,
        timeout: @timeout
      ]) do
        {output, 0} ->
          results = parse_ripgrep_output(output, params)
          {:ok, Enum.take(results, @max_results)}

        {_output, 1} ->
          # Exit code 1 means no matches found
          {:ok, []}

        {output, exit_code} ->
          Logger.warning("Ripgrep command failed",
            session_id: Map.get(context, :session_id),
            exit_code: exit_code,
            output: String.slice(output, 0, 500)
          )
          {:error, "search failed: #{String.slice(output, 0, 200)}"}
      end
    rescue
      error ->
        Logger.error("Ripgrep execution error",
          session_id: Map.get(context, :session_id),
          error: inspect(error),
          stacktrace: inspect(__STACKTRACE__)
        )
        {:error, "search execution failed"}
    end
  end

  defp build_ripgrep_args(params) do
    base_args = [
      "--json",
      "--with-filename",
      "--line-number"
    ]

    base_args
    |> add_case_sensitivity(params.case_sensitive)
    |> add_context_lines(params.context_lines)
    |> add_max_depth(params.max_depth)
    |> add_hidden_files(params.include_hidden)
    |> add_file_pattern(params.file_pattern)
    |> add_pattern(params.pattern)
  end

  defp add_case_sensitivity(args, true), do: args
  defp add_case_sensitivity(args, false), do: ["--ignore-case" | args]

  defp add_context_lines(args, 0), do: args
  defp add_context_lines(args, lines), do: ["--context", to_string(lines) | args]

  defp add_max_depth(args, depth), do: ["--max-depth", to_string(depth) | args]

  defp add_hidden_files(args, true), do: ["--hidden" | args]
  defp add_hidden_files(args, false), do: args

  defp add_file_pattern(args, "*"), do: args
  defp add_file_pattern(args, pattern), do: ["--glob", pattern | args]

  defp add_pattern(args, pattern), do: args ++ [pattern]

  defp parse_ripgrep_output(output, _params) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_json_line/1)
    |> Enum.filter(& &1)
    |> Enum.map(&format_match/1)
  end

  defp parse_json_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "match", "data" => data}} ->
        data

      _ ->
        nil
    end
  rescue
    _ ->
      nil
  end

  defp format_match(data) do
    %{
      "file" => Map.get(data, "path", %{}) |> Map.get("text", ""),
      "line_number" => Map.get(data, "line_number", 0),
      "line" => Map.get(data, "lines", %{}) |> Map.get("text", ""),
      "match_start" => get_match_start(data),
      "match_end" => get_match_end(data),
      "submatches" => get_submatches(data)
    }
  end

  defp get_match_start(data) do
    data
    |> Map.get("submatches", [])
    |> List.first()
    |> case do
      %{"start" => start} -> start
      _ -> 0
    end
  end

  defp get_match_end(data) do
    data
    |> Map.get("submatches", [])
    |> List.first()
    |> case do
      %{"end" => end_pos} -> end_pos
      _ -> 0
    end
  end

  defp get_submatches(data) do
    Map.get(data, "submatches", [])
  end
end