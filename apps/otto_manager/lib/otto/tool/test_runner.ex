defmodule Otto.Tool.TestRunner do
  @moduledoc """
  Tool for executing mix test and parsing results within the agent's working directory.

  This tool provides test execution capabilities with result parsing,
  coverage reporting, and output capture. All tests are run within
  the configured working directory for isolation.
  """

  use Otto.Tool
  require Logger

  @default_timeout 300_000  # 5 minutes
  @max_output_size 10 * 1024 * 1024  # 10 MB

  @impl Otto.Tool
  def execute(args, context) do
    with :ok <- validate_args(args),
         {:ok, working_dir} <- get_working_dir(context),
         {:ok, test_options} <- build_test_options(args),
         {:ok, result} <- run_mix_test(test_options, working_dir, context) do

      Logger.info("Test execution completed",
        session_id: Map.get(context, :session_id),
        working_dir: working_dir,
        test_count: result.test_count,
        failure_count: result.failure_count,
        success: result.success
      )

      {:ok, result}
    else
      {:error, reason} ->
        Logger.warning("Test execution failed",
          session_id: Map.get(context, :session_id),
          working_dir: Map.get(context, :working_dir),
          reason: reason
        )
        {:error, reason}
    end
  end

  @impl Otto.Tool
  def validate_args(args) do
    with :ok <- validate_test_files(args),
         :ok <- validate_options(args) do
      :ok
    end
  end

  @impl Otto.Tool
  def sandbox_config do
    %{
      timeout: @default_timeout + 30_000,  # Add buffer for cleanup
      memory_limit: 500 * 1024 * 1024,     # 500 MB for test compilation
      filesystem_access: :read_write,       # Tests may create temp files
      network_access: false,                # Tests should not need network
      environment_variables: ["MIX_ENV"]    # Allow setting test environment
    }
  end

  @impl Otto.Tool
  def metadata do
    %{
      name: "test_runner",
      description: "Execute mix test and parse results within the working directory",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "test_files" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Specific test files to run (relative to working_dir)",
            "default" => []
          },
          "test_pattern" => %{
            "type" => "string",
            "description" => "Pattern to match test names",
            "default" => ""
          },
          "only_tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Run only tests with these tags",
            "default" => []
          },
          "exclude_tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Exclude tests with these tags",
            "default" => []
          },
          "coverage" => %{
            "type" => "boolean",
            "description" => "Generate coverage report",
            "default" => false
          },
          "verbose" => %{
            "type" => "boolean",
            "description" => "Run tests in verbose mode",
            "default" => false
          },
          "seed" => %{
            "type" => "integer",
            "description" => "Random seed for test execution",
            "minimum" => 0
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Test execution timeout in milliseconds",
            "minimum" => 10000,
            "maximum" => 600000,
            "default" => @default_timeout
          }
        }
      },
      examples: [
        %{
          "description" => "Run all tests",
          "args" => %{},
          "result" => %{
            "success" => true,
            "test_count" => 42,
            "failure_count" => 0,
            "execution_time" => 1250,
            "output" => "...\n42 tests, 0 failures\n",
            "failures" => []
          }
        },
        %{
          "description" => "Run specific test file with coverage",
          "args" => %{
            "test_files" => ["test/my_module_test.exs"],
            "coverage" => true
          },
          "result" => %{
            "success" => true,
            "test_count" => 5,
            "failure_count" => 0,
            "execution_time" => 500,
            "coverage" => %{"percentage" => 85.2},
            "output" => ".....\n5 tests, 0 failures\n",
            "failures" => []
          }
        }
      ],
      version: "1.0.0"
    }
  end

  # Private helper functions

  defp validate_test_files(args) do
    case Map.get(args, "test_files", []) do
      files when is_list(files) ->
        if Enum.all?(files, &is_binary/1) do
          :ok
        else
          {:error, "all test_files must be strings"}
        end

      _ ->
        {:error, "test_files must be an array of strings"}
    end
  end

  defp validate_options(args) do
    with :ok <- validate_tags(args, "only_tags"),
         :ok <- validate_tags(args, "exclude_tags"),
         :ok <- validate_timeout(args) do
      :ok
    end
  end

  defp validate_tags(args, key) do
    case Map.get(args, key, []) do
      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1) do
          :ok
        else
          {:error, "all #{key} must be strings"}
        end

      _ ->
        {:error, "#{key} must be an array of strings"}
    end
  end

  defp validate_timeout(args) do
    case Map.get(args, "timeout", @default_timeout) do
      timeout when is_integer(timeout) and timeout >= 10_000 and timeout <= 600_000 ->
        :ok

      _ ->
        {:error, "timeout must be an integer between 10000 and 600000 milliseconds"}
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

  defp build_test_options(args) do
    options = %{
      test_files: Map.get(args, "test_files", []),
      test_pattern: Map.get(args, "test_pattern", ""),
      only_tags: Map.get(args, "only_tags", []),
      exclude_tags: Map.get(args, "exclude_tags", []),
      coverage: Map.get(args, "coverage", false),
      verbose: Map.get(args, "verbose", false),
      seed: Map.get(args, "seed"),
      timeout: Map.get(args, "timeout", @default_timeout)
    }

    {:ok, options}
  end

  defp run_mix_test(options, working_dir, context) do
    cmd_args = build_mix_test_args(options)
    env = build_test_environment(options)

    start_time = System.monotonic_time(:millisecond)

    try do
      case System.cmd("mix", cmd_args, [
        cd: working_dir,
        env: env,
        stderr_to_stdout: true,
        timeout: options.timeout
      ]) do
        {output, exit_code} ->
          execution_time = System.monotonic_time(:millisecond) - start_time

          if byte_size(output) > @max_output_size do
            truncated_output = String.slice(output, 0, @max_output_size)
            result = parse_test_output(truncated_output, exit_code, execution_time, options)
            {:ok, %{result | output_truncated: true}}
          else
            result = parse_test_output(output, exit_code, execution_time, options)
            {:ok, result}
          end
      end
    rescue
      error ->
        Logger.error("Mix test execution error",
          session_id: Map.get(context, :session_id),
          error: inspect(error)
        )
        {:error, "test execution failed: #{inspect(error)}"}
    end
  end

  defp build_mix_test_args(options) do
    base_args = ["test"]

    base_args
    |> add_test_files(options.test_files)
    |> add_test_pattern(options.test_pattern)
    |> add_only_tags(options.only_tags)
    |> add_exclude_tags(options.exclude_tags)
    |> add_coverage(options.coverage)
    |> add_verbose(options.verbose)
    |> add_seed(options.seed)
  end

  defp add_test_files(args, []), do: args
  defp add_test_files(args, test_files), do: args ++ test_files

  defp add_test_pattern(args, ""), do: args
  defp add_test_pattern(args, pattern), do: args ++ ["--match", pattern]

  defp add_only_tags(args, []), do: args
  defp add_only_tags(args, tags) do
    Enum.reduce(tags, args, fn tag, acc ->
      acc ++ ["--only", tag]
    end)
  end

  defp add_exclude_tags(args, []), do: args
  defp add_exclude_tags(args, tags) do
    Enum.reduce(tags, args, fn tag, acc ->
      acc ++ ["--exclude", tag]
    end)
  end

  defp add_coverage(args, false), do: args
  defp add_coverage(args, true), do: args ++ ["--cover"]

  defp add_verbose(args, false), do: args
  defp add_verbose(args, true), do: args ++ ["--trace"]

  defp add_seed(args, nil), do: args
  defp add_seed(args, seed), do: args ++ ["--seed", to_string(seed)]

  defp build_test_environment(options) do
    base_env = [
      {"MIX_ENV", "test"}
    ]

    if options.coverage do
      [{"COVERAGE", "true"} | base_env]
    else
      base_env
    end
  end

  defp parse_test_output(output, exit_code, execution_time, options) do
    %{
      success: exit_code == 0,
      exit_code: exit_code,
      execution_time: execution_time,
      output: output,
      test_count: extract_test_count(output),
      failure_count: extract_failure_count(output),
      failures: extract_failures(output),
      coverage: extract_coverage(output, options.coverage),
      output_truncated: false
    }
  end

  defp extract_test_count(output) do
    case Regex.run(~r/(\d+) tests?, /, output) do
      [_, count] -> String.to_integer(count)
      _ -> 0
    end
  end

  defp extract_failure_count(output) do
    case Regex.run(~r/(\d+) failures?/, output) do
      [_, count] -> String.to_integer(count)
      _ -> 0
    end
  end

  defp extract_failures(output) do
    # Extract failure details - this is a simplified parser
    # In a production system, you might want more sophisticated parsing
    failure_pattern = ~r/\s+\d+\)\s+(.+?)\n\s+(.*?)\n\s+(.*?):(\d+)/s

    Regex.scan(failure_pattern, output)
    |> Enum.map(fn [_, test_name, error, file, line] ->
      %{
        test: String.trim(test_name),
        error: String.trim(error),
        file: String.trim(file),
        line: String.to_integer(line)
      }
    end)
  end

  defp extract_coverage(output, true) do
    case Regex.run(~r/(\d+\.\d+)%\s+\|\s+Total/, output) do
      [_, percentage] ->
        %{percentage: String.to_float(percentage)}

      _ ->
        %{percentage: 0.0}
    end
  end

  defp extract_coverage(_output, false), do: nil
end