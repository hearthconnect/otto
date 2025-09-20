defmodule Otto.Tool.FS.Write do
  @moduledoc """
  Tool for safely writing files within the agent's working directory.

  This tool provides sandboxed file writing capabilities with strict path validation
  to ensure files can only be written within the configured working directory.
  Includes safety checks for file size limits and directory creation.
  """

  use Otto.Tool
  require Logger

  @max_file_size 10 * 1024 * 1024  # 10 MB
  @max_content_length 10 * 1024 * 1024  # 10 MB

  @impl Otto.Tool
  def execute(args, context) do
    with :ok <- validate_args(args),
         {:ok, file_path} <- get_file_path(args),
         {:ok, content} <- get_content(args),
         {:ok, working_dir} <- get_working_dir(context),
         :ok <- validate_path_within_working_dir(file_path, working_dir),
         :ok <- validate_content_size(content),
         {:ok, full_path} <- prepare_file_path(file_path, working_dir),
         :ok <- ensure_parent_directory(full_path),
         :ok <- write_file_safely(full_path, content, args) do

      file_info = File.stat!(full_path)

      Logger.info("File write successful",
        session_id: Map.get(context, :session_id),
        file_path: full_path,
        content_size: byte_size(content),
        mode: get_write_mode(args)
      )

      {:ok, %{
        file_path: full_path,
        size: file_info.size,
        mode: get_write_mode(args),
        created_at: file_info.mtime
      }}
    else
      {:error, reason} ->
        Logger.warning("File write failed",
          session_id: Map.get(context, :session_id),
          file_path: Map.get(args, "file_path"),
          reason: reason
        )
        {:error, reason}
    end
  end

  @impl Otto.Tool
  def validate_args(args) do
    with {:ok, _} <- validate_file_path(args),
         {:ok, _} <- validate_content(args),
         :ok <- validate_mode(args) do
      :ok
    end
  end

  @impl Otto.Tool
  def sandbox_config do
    %{
      timeout: 60_000,
      memory_limit: 100 * 1024 * 1024,  # 100 MB
      filesystem_access: :read_write,
      network_access: false
    }
  end

  @impl Otto.Tool
  def metadata do
    %{
      name: "fs_write",
      description: "Write content to a file within the agent's working directory",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to write (relative to working directory)"
          },
          "content" => %{
            "type" => "string",
            "description" => "Content to write to the file"
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["write", "append"],
            "description" => "Write mode: 'write' (default) overwrites, 'append' adds to end",
            "default" => "write"
          },
          "create_dirs" => %{
            "type" => "boolean",
            "description" => "Create parent directories if they don't exist",
            "default" => true
          }
        },
        "required" => ["file_path", "content"]
      },
      examples: [
        %{
          "description" => "Write a new file",
          "args" => %{
            "file_path" => "src/hello.ex",
            "content" => "defmodule Hello do\n  def world, do: \"Hello, World!\"\nend\n"
          },
          "result" => %{
            "file_path" => "/agent/working/dir/src/hello.ex",
            "size" => 56,
            "mode" => "write"
          }
        },
        %{
          "description" => "Append to an existing file",
          "args" => %{
            "file_path" => "log/debug.log",
            "content" => "[INFO] New log entry\n",
            "mode" => "append"
          },
          "result" => %{
            "file_path" => "/agent/working/dir/log/debug.log",
            "size" => 1024,
            "mode" => "append"
          }
        }
      ],
      version: "1.0.0"
    }
  end

  # Private helper functions

  defp validate_file_path(args) do
    case Map.get(args, "file_path") do
      nil ->
        {:error, "file_path parameter is required"}

      file_path when is_binary(file_path) and byte_size(file_path) > 0 ->
        if String.contains?(file_path, ["../", "..\\"]) do
          {:error, "file_path cannot contain parent directory references"}
        else
          {:ok, file_path}
        end

      _ ->
        {:error, "file_path must be a non-empty string"}
    end
  end

  defp validate_content(args) do
    case Map.get(args, "content") do
      nil ->
        {:error, "content parameter is required"}

      content when is_binary(content) ->
        {:ok, content}

      _ ->
        {:error, "content must be a string"}
    end
  end

  defp validate_mode(args) do
    case Map.get(args, "mode", "write") do
      mode when mode in ["write", "append"] ->
        :ok

      _ ->
        {:error, "mode must be 'write' or 'append'"}
    end
  end

  defp get_file_path(args) do
    case Map.get(args, "file_path") do
      file_path when is_binary(file_path) ->
        {:ok, file_path}
      _ ->
        {:error, "invalid file_path"}
    end
  end

  defp get_content(args) do
    case Map.get(args, "content") do
      content when is_binary(content) ->
        {:ok, content}
      _ ->
        {:error, "invalid content"}
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

  defp get_write_mode(args) do
    Map.get(args, "mode", "write")
  end

  defp validate_path_within_working_dir(file_path, working_dir) do
    expanded_working_dir = Path.expand(working_dir)
    expanded_file_path = Path.expand(file_path, working_dir)

    if String.starts_with?(expanded_file_path, expanded_working_dir) do
      :ok
    else
      {:error, "file_path is outside working directory"}
    end
  end

  defp validate_content_size(content) do
    if byte_size(content) > @max_content_length do
      {:error, "content too large (max #{@max_content_length} bytes)"}
    else
      :ok
    end
  end

  defp prepare_file_path(file_path, working_dir) do
    full_path = Path.expand(file_path, working_dir)
    {:ok, full_path}
  end

  defp ensure_parent_directory(full_path) do
    parent_dir = Path.dirname(full_path)

    case File.mkdir_p(parent_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "failed to create parent directory: #{inspect(reason)}"}
    end
  end

  defp write_file_safely(full_path, content, args) do
    mode = get_write_mode(args)

    # Check if file exists and get current size for append mode
    existing_size =
      case File.stat(full_path) do
        {:ok, %{size: size}} -> size
        {:error, _} -> 0
      end

    # Calculate total size after write
    total_size = case mode do
      "append" -> existing_size + byte_size(content)
      "write" -> byte_size(content)
    end

    if total_size > @max_file_size do
      {:error, "resulting file would be too large (max #{@max_file_size} bytes)"}
    else
      case mode do
        "write" ->
          case File.write(full_path, content) do
            :ok -> :ok
            {:error, reason} -> {:error, "failed to write file: #{inspect(reason)}"}
          end

        "append" ->
          case File.write(full_path, content, [:append]) do
            :ok -> :ok
            {:error, reason} -> {:error, "failed to append to file: #{inspect(reason)}"}
          end
      end
    end
  end
end