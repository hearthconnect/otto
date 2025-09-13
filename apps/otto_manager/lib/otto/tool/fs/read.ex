defmodule Otto.Tool.FS.Read do
  @moduledoc """
  Tool for safely reading files within the agent's working directory.

  This tool provides sandboxed file reading capabilities with strict path validation
  to ensure files can only be read from within the configured working directory.
  """

  use Otto.Tool
  require Logger

  @impl Otto.Tool
  def execute(args, context) do
    with :ok <- validate_args(args),
         {:ok, file_path} <- get_file_path(args),
         {:ok, working_dir} <- get_working_dir(context),
         :ok <- validate_path_within_working_dir(file_path, working_dir),
         {:ok, content} <- read_file_safely(file_path) do

      Logger.info("File read successful",
        session_id: Map.get(context, :session_id),
        file_path: file_path,
        content_size: byte_size(content)
      )

      {:ok, %{
        file_path: file_path,
        content: content,
        size: byte_size(content),
        encoding: detect_encoding(content)
      }}
    else
      {:error, reason} ->
        Logger.warning("File read failed",
          session_id: Map.get(context, :session_id),
          file_path: Map.get(args, "file_path"),
          reason: reason
        )
        {:error, reason}
    end
  end

  @impl Otto.Tool
  def validate_args(args) do
    case Map.get(args, "file_path") do
      nil ->
        {:error, "file_path parameter is required"}

      file_path when is_binary(file_path) and byte_size(file_path) > 0 ->
        :ok

      _ ->
        {:error, "file_path must be a non-empty string"}
    end
  end

  @impl Otto.Tool
  def sandbox_config do
    %{
      timeout: 30_000,
      memory_limit: 50 * 1024 * 1024,  # 50 MB
      filesystem_access: :read_only,
      network_access: false
    }
  end

  @impl Otto.Tool
  def metadata do
    %{
      name: "fs_read",
      description: "Read file contents from within the agent's working directory",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to read (relative to working directory)"
          }
        },
        "required" => ["file_path"]
      },
      examples: [
        %{
          "description" => "Read a text file",
          "args" => %{"file_path" => "src/main.ex"},
          "result" => %{
            "file_path" => "/agent/working/dir/src/main.ex",
            "content" => "defmodule Main do...",
            "size" => 256,
            "encoding" => "utf8"
          }
        }
      ],
      version: "1.0.0"
    }
  end

  # Private helper functions

  defp get_file_path(args) do
    case Map.get(args, "file_path") do
      file_path when is_binary(file_path) ->
        {:ok, file_path}
      _ ->
        {:error, "invalid file_path"}
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

  defp validate_path_within_working_dir(file_path, working_dir) do
    expanded_working_dir = Path.expand(working_dir)
    expanded_file_path = Path.expand(file_path, working_dir)

    if String.starts_with?(expanded_file_path, expanded_working_dir) do
      :ok
    else
      {:error, "file_path is outside working directory"}
    end
  end

  defp read_file_safely(file_path) do
    # Expand path relative to working directory
    case File.read(file_path) do
      {:ok, content} ->
        # Check file size to prevent memory exhaustion
        if byte_size(content) > 10 * 1024 * 1024 do  # 10 MB limit
          {:error, "file too large (max 10MB)"}
        else
          {:ok, content}
        end

      {:error, :enoent} ->
        {:error, "file not found"}

      {:error, :eacces} ->
        {:error, "permission denied"}

      {:error, :eisdir} ->
        {:error, "path is a directory, not a file"}

      {:error, reason} ->
        {:error, "failed to read file: #{inspect(reason)}"}
    end
  end

  defp detect_encoding(content) do
    case String.valid?(content) do
      true -> "utf8"
      false -> "binary"
    end
  end
end