defmodule Otto.Checkpointer do
  @moduledoc """
  Filesystem-based artifact persistence for Otto agents.

  Handles atomic writes of agent artifacts with proper directory structure
  and retention policies.
  """

  use GenServer
  require Logger
  alias Otto.ArtifactRef

  @default_base_path "var/otto/sessions"
  @default_retention_days 7

  defstruct [
    base_path: @default_base_path,
    retention_days: @default_retention_days
  ]

  @type artifact_type :: :transcript | :result | :intermediate
  @type session_id :: String.t()

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Saves an artifact to the filesystem"
  def save_artifact(session_id, artifact_type, content, opts \\ []) do
    GenServer.call(__MODULE__, {:save_artifact, session_id, artifact_type, content, opts})
  end

  @doc "Loads an artifact from the filesystem"
  def load_artifact(%ArtifactRef{} = ref) do
    GenServer.call(__MODULE__, {:load_artifact, ref})
  end

  @doc "Lists all artifacts for a session"
  def list_artifacts(session_id) do
    GenServer.call(__MODULE__, {:list_artifacts, session_id})
  end

  @doc "Cleans up expired artifacts"
  def cleanup_expired do
    GenServer.call(__MODULE__, :cleanup_expired)
  end

  @doc "Gets storage statistics"
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  ## Server Implementation

  @impl true
  def init(opts) do
    base_path = Keyword.get(opts, :base_path, @default_base_path)
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)

    # Ensure base directory exists
    File.mkdir_p!(base_path)

    state = %__MODULE__{
      base_path: base_path,
      retention_days: retention_days
    }

    Logger.info("Checkpointer started with base_path: #{base_path}")
    {:ok, state}
  end

  @impl true
  def handle_call({:save_artifact, session_id, artifact_type, content, opts}, _from, state) do
    try do
      artifact_ref = do_save_artifact(state, session_id, artifact_type, content, opts)
      {:reply, {:ok, artifact_ref}, state}
    rescue
      error ->
        Logger.error("Failed to save artifact: #{inspect(error)}")
        {:reply, {:error, {:save_failed, error}}, state}
    end
  end

  @impl true
  def handle_call({:load_artifact, ref}, _from, state) do
    try do
      content = do_load_artifact(ref)
      {:reply, {:ok, content}, state}
    rescue
      error ->
        Logger.error("Failed to load artifact: #{inspect(error)}")
        {:reply, {:error, {:load_failed, error}}, state}
    end
  end

  @impl true
  def handle_call({:list_artifacts, session_id}, _from, state) do
    try do
      artifacts = do_list_artifacts(state, session_id)
      {:reply, {:ok, artifacts}, state}
    rescue
      error ->
        Logger.error("Failed to list artifacts: #{inspect(error)}")
        {:reply, {:error, {:list_failed, error}}, state}
    end
  end

  @impl true
  def handle_call(:cleanup_expired, _from, state) do
    try do
      cleaned = do_cleanup_expired(state)
      {:reply, {:ok, cleaned}, state}
    rescue
      error ->
        Logger.error("Failed to cleanup expired artifacts: #{inspect(error)}")
        {:reply, {:error, {:cleanup_failed, error}}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    try do
      stats = do_get_stats(state)
      {:reply, {:ok, stats}, state}
    rescue
      error ->
        Logger.error("Failed to get stats: #{inspect(error)}")
        {:reply, {:error, {:stats_failed, error}}, state}
    end
  end

  ## Private Implementation

  defp do_save_artifact(state, session_id, artifact_type, content, opts) do
    timestamp = DateTime.utc_now()
    filename = generate_filename(artifact_type, timestamp, opts)
    session_dir = Path.join(state.base_path, session_id)
    file_path = Path.join(session_dir, filename)

    # Ensure session directory exists
    File.mkdir_p!(session_dir)

    # Write to temporary file first (atomic write)
    temp_path = file_path <> ".tmp"
    File.write!(temp_path, content)

    # Atomic rename
    File.rename!(temp_path, file_path)

    # Calculate checksum
    checksum = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    # Get file stats
    %{size: size} = File.stat!(file_path)

    %ArtifactRef{
      path: file_path,
      type: artifact_type,
      size: size,
      checksum: checksum,
      created_at: timestamp,
      session_id: session_id
    }
  end

  defp do_load_artifact(%ArtifactRef{path: path}) do
    File.read!(path)
  end

  defp do_list_artifacts(state, session_id) do
    session_dir = Path.join(state.base_path, session_id)

    if File.exists?(session_dir) do
      File.ls!(session_dir)
      |> Enum.reject(&String.ends_with?(&1, ".tmp"))
      |> Enum.map(fn filename ->
        path = Path.join(session_dir, filename)
        %{size: size} = File.stat!(path)

        # Parse artifact type from filename
        artifact_type = parse_artifact_type(filename)

        %ArtifactRef{
          path: path,
          type: artifact_type,
          size: size,
          checksum: nil,  # Would calculate if needed
          created_at: nil,  # Would parse from filename if needed
          session_id: session_id
        }
      end)
    else
      []
    end
  end

  defp do_cleanup_expired(state) do
    cutoff_date = DateTime.utc_now()
                  |> DateTime.add(-state.retention_days, :day)

    if File.exists?(state.base_path) do
      File.ls!(state.base_path)
      |> Enum.reduce(0, fn session_id, count ->
        session_dir = Path.join(state.base_path, session_id)
        session_stat = File.stat!(session_dir)

        if DateTime.from_unix!(session_stat.mtime) < cutoff_date do
          File.rm_rf!(session_dir)
          count + 1
        else
          count
        end
      end)
    else
      0
    end
  end

  defp do_get_stats(state) do
    if File.exists?(state.base_path) do
      {session_count, total_size, artifact_count} =
        File.ls!(state.base_path)
        |> Enum.reduce({0, 0, 0}, fn session_id, {sessions, size, artifacts} ->
          session_dir = Path.join(state.base_path, session_id)
          if File.dir?(session_dir) do
            {session_size, session_artifacts} = calculate_session_size(session_dir)
            {sessions + 1, size + session_size, artifacts + session_artifacts}
          else
            {sessions, size, artifacts}
          end
        end)

      %{
        session_count: session_count,
        total_size: total_size,
        artifact_count: artifact_count,
        base_path: state.base_path,
        retention_days: state.retention_days
      }
    else
      %{
        session_count: 0,
        total_size: 0,
        artifact_count: 0,
        base_path: state.base_path,
        retention_days: state.retention_days
      }
    end
  end

  defp generate_filename(artifact_type, timestamp, opts) do
    base_name = Keyword.get(opts, :filename, to_string(artifact_type))
    iso_timestamp = DateTime.to_iso8601(timestamp, :basic)
    "#{iso_timestamp}_#{base_name}"
  end

  defp parse_artifact_type(filename) do
    cond do
      String.contains?(filename, "transcript") -> :transcript
      String.contains?(filename, "result") -> :result
      true -> :intermediate
    end
  end

  defp calculate_session_size(session_dir) do
    File.ls!(session_dir)
    |> Enum.reject(&String.ends_with?(&1, ".tmp"))
    |> Enum.reduce({0, 0}, fn filename, {size_acc, count_acc} ->
      file_path = Path.join(session_dir, filename)
      %{size: size} = File.stat!(file_path)
      {size_acc + size, count_acc + 1}
    end)
  end
end