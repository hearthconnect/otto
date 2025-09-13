defmodule Otto.Manager.Checkpointer do
  @moduledoc """
  GenServer for managing filesystem-based checkpoint persistence.

  The Checkpointer provides durable storage for agent states, contexts, and
  checkpoints that need to survive process restarts. It organizes data by
  agent ID and checkpoint name, with automatic cleanup and metadata tracking.
  """

  use GenServer
  require Logger

  @type agent_id :: String.t()
  @type checkpoint_id :: String.t()
  @type checkpoint_data :: map()

  defstruct [
    :checkpoint_dir,
    :name,
    cleanup_interval: 86_400_000  # 24 hours
  ]

  ## Client API

  @doc """
  Starts the Checkpointer GenServer.

  ## Options
  - `:name` - Process name for the GenServer
  - `:checkpoint_dir` - Directory for storing checkpoints (default: "./checkpoints")
  - `:cleanup_interval` - How often to run cleanup in milliseconds
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Saves a checkpoint to disk.

  ## Parameters
  - `checkpointer` - GenServer process identifier
  - `agent_id` - Unique identifier for the agent
  - `checkpoint_id` - Unique identifier for the checkpoint
  - `data` - Checkpoint data to save
  """
  @spec save_checkpoint(GenServer.server(), agent_id(), checkpoint_id(), checkpoint_data()) :: :ok | {:error, any()}
  def save_checkpoint(checkpointer, agent_id, checkpoint_id, data) do
    GenServer.call(checkpointer, {:save_checkpoint, agent_id, checkpoint_id, data})
  end

  @doc """
  Loads a checkpoint from disk.
  """
  @spec load_checkpoint(GenServer.server(), agent_id(), checkpoint_id()) :: {:ok, checkpoint_data()} | {:error, :not_found | any()}
  def load_checkpoint(checkpointer, agent_id, checkpoint_id) do
    GenServer.call(checkpointer, {:load_checkpoint, agent_id, checkpoint_id})
  end

  @doc """
  Deletes a checkpoint from disk.
  """
  @spec delete_checkpoint(GenServer.server(), agent_id(), checkpoint_id()) :: :ok | {:error, any()}
  def delete_checkpoint(checkpointer, agent_id, checkpoint_id) do
    GenServer.call(checkpointer, {:delete_checkpoint, agent_id, checkpoint_id})
  end

  @doc """
  Lists all checkpoint IDs for a specific agent.
  """
  @spec list_checkpoints(GenServer.server(), agent_id()) :: [checkpoint_id()]
  def list_checkpoints(checkpointer, agent_id) do
    GenServer.call(checkpointer, {:list_checkpoints, agent_id})
  end

  @doc """
  Lists all agent IDs that have checkpoints.
  """
  @spec list_agents(GenServer.server()) :: [agent_id()]
  def list_agents(checkpointer) do
    GenServer.call(checkpointer, :list_agents)
  end

  @doc """
  Gets metadata for a specific checkpoint.
  """
  @spec get_checkpoint_metadata(GenServer.server(), agent_id(), checkpoint_id()) :: {:ok, map()} | {:error, :not_found | any()}
  def get_checkpoint_metadata(checkpointer, agent_id, checkpoint_id) do
    GenServer.call(checkpointer, {:get_checkpoint_metadata, agent_id, checkpoint_id})
  end

  @doc """
  Cleans up old checkpoints based on age.

  ## Parameters
  - `checkpointer` - GenServer process identifier
  - `max_age_days` - Maximum age in days (default: 30)
  """
  @spec cleanup_old_checkpoints(GenServer.server(), keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def cleanup_old_checkpoints(checkpointer, opts \\ []) do
    GenServer.call(checkpointer, {:cleanup_old_checkpoints, opts})
  end

  @doc """
  Cleans up all checkpoints for a specific agent.
  """
  @spec cleanup_agent_checkpoints(GenServer.server(), agent_id()) :: :ok | {:error, any()}
  def cleanup_agent_checkpoints(checkpointer, agent_id) do
    GenServer.call(checkpointer, {:cleanup_agent_checkpoints, agent_id})
  end

  @doc """
  Gets storage statistics.
  """
  @spec get_stats(GenServer.server()) :: map()
  def get_stats(checkpointer) do
    GenServer.call(checkpointer, :get_stats)
  end

  ## Server Implementation

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    checkpoint_dir = Keyword.get(opts, :checkpoint_dir, "./checkpoints")
    cleanup_interval = Keyword.get(opts, :cleanup_interval, 86_400_000)

    # Ensure checkpoint directory exists
    case File.mkdir_p(checkpoint_dir) do
      :ok ->
        Logger.debug("Started Otto.Manager.Checkpointer with dir: #{checkpoint_dir}")

        state = %__MODULE__{
          checkpoint_dir: checkpoint_dir,
          name: name,
          cleanup_interval: cleanup_interval
        }

        # Schedule periodic cleanup
        Process.send_after(self(), :periodic_cleanup, cleanup_interval)

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to create checkpoint directory #{checkpoint_dir}: #{inspect(reason)}")
        {:stop, {:error, :checkpoint_dir_creation_failed}}
    end
  end

  @impl true
  def handle_call({:save_checkpoint, agent_id, checkpoint_id, data}, _from, state) do
    case do_save_checkpoint(state, agent_id, checkpoint_id, data) do
      :ok ->
        Logger.debug("Saved checkpoint: #{agent_id}/#{checkpoint_id}")
        try do
          :telemetry.execute([:otto, :checkpointer, :save], %{}, %{agent_id: agent_id, checkpoint_id: checkpoint_id})
        rescue
          UndefinedFunctionError -> :ok
        end
        {:reply, :ok, state}

      {:error, reason} = error ->
        Logger.error("Failed to save checkpoint #{agent_id}/#{checkpoint_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:load_checkpoint, agent_id, checkpoint_id}, _from, state) do
    case do_load_checkpoint(state, agent_id, checkpoint_id) do
      {:ok, data} ->
        Logger.debug("Loaded checkpoint: #{agent_id}/#{checkpoint_id}")
        try do
          :telemetry.execute([:otto, :checkpointer, :load], %{}, %{agent_id: agent_id, checkpoint_id: checkpoint_id})
        rescue
          UndefinedFunctionError -> :ok
        end
        {:reply, {:ok, data}, state}

      {:error, :enoent} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} = error ->
        Logger.error("Failed to load checkpoint #{agent_id}/#{checkpoint_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delete_checkpoint, agent_id, checkpoint_id}, _from, state) do
    case do_delete_checkpoint(state, agent_id, checkpoint_id) do
      :ok ->
        Logger.debug("Deleted checkpoint: #{agent_id}/#{checkpoint_id}")
        {:reply, :ok, state}

      {:error, reason} = error ->
        Logger.error("Failed to delete checkpoint #{agent_id}/#{checkpoint_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_checkpoints, agent_id}, _from, state) do
    checkpoints = do_list_checkpoints(state, agent_id)
    {:reply, checkpoints, state}
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    agents = do_list_agents(state)
    {:reply, agents, state}
  end

  @impl true
  def handle_call({:get_checkpoint_metadata, agent_id, checkpoint_id}, _from, state) do
    case do_get_checkpoint_metadata(state, agent_id, checkpoint_id) do
      {:ok, metadata} ->
        {:reply, {:ok, metadata}, state}

      {:error, :enoent} ->
        {:reply, {:error, :not_found}, state}

      {:error, reason} = error ->
        Logger.error("Failed to get checkpoint metadata #{agent_id}/#{checkpoint_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:cleanup_old_checkpoints, opts}, _from, state) do
    max_age_days = Keyword.get(opts, :max_age_days, 30)

    case do_cleanup_old_checkpoints(state, max_age_days) do
      {:ok, count} ->
        Logger.info("Cleaned up #{count} old checkpoints (older than #{max_age_days} days)")
        {:reply, {:ok, count}, state}

      {:error, reason} = error ->
        Logger.error("Failed to cleanup old checkpoints: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:cleanup_agent_checkpoints, agent_id}, _from, state) do
    result = do_cleanup_agent_checkpoints(state, agent_id)
    Logger.info("Cleaned up all checkpoints for agent: #{agent_id} - Result: #{inspect(result)}")
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = do_get_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:periodic_cleanup, state) do
    # Run automatic cleanup of old checkpoints (30+ days)
    case do_cleanup_old_checkpoints(state, 30) do
      {:ok, count} when count > 0 ->
        Logger.info("Periodic cleanup removed #{count} old checkpoints")

      {:ok, 0} ->
        :ok  # No cleanup needed

      {:error, reason} ->
        Logger.error("Periodic cleanup failed: #{inspect(reason)}")
    end

    # Schedule next cleanup
    Process.send_after(self(), :periodic_cleanup, state.cleanup_interval)

    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug("Otto.Manager.Checkpointer terminating: #{inspect(reason)}")
    :ok
  end

  ## Private Functions

  defp do_save_checkpoint(state, agent_id, checkpoint_id, data) do
    agent_dir = Path.join(state.checkpoint_dir, sanitize_filename(agent_id))
    checkpoint_path = Path.join(agent_dir, "#{sanitize_filename(checkpoint_id)}.json")

    # Ensure agent directory exists
    with :ok <- File.mkdir_p(agent_dir),
         # Add metadata to the data
         enriched_data <- add_metadata(data, agent_id, checkpoint_id),
         # Encode and write
         {:ok, json} <- Jason.encode(enriched_data),
         :ok <- File.write(checkpoint_path, json) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_load_checkpoint(state, agent_id, checkpoint_id) do
    checkpoint_path = get_checkpoint_path(state, agent_id, checkpoint_id)

    with {:ok, json} <- File.read(checkpoint_path),
         {:ok, data} <- Jason.decode(json, keys: :atoms) do
      {:ok, data}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_delete_checkpoint(state, agent_id, checkpoint_id) do
    checkpoint_path = get_checkpoint_path(state, agent_id, checkpoint_id)
    File.rm(checkpoint_path)
  end

  defp do_list_checkpoints(state, agent_id) do
    agent_dir = Path.join(state.checkpoint_dir, sanitize_filename(agent_id))

    case File.ls(agent_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.replace_suffix(&1, ".json", ""))

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  defp do_list_agents(state) do
    case File.ls(state.checkpoint_dir) do
      {:ok, dirs} ->
        dirs
        |> Enum.filter(fn dir ->
          dir_path = Path.join(state.checkpoint_dir, dir)
          File.dir?(dir_path)
        end)

      {:error, _reason} ->
        []
    end
  end

  defp do_get_checkpoint_metadata(state, agent_id, checkpoint_id) do
    checkpoint_path = get_checkpoint_path(state, agent_id, checkpoint_id)

    case File.stat(checkpoint_path) do
      {:ok, stat} ->
        metadata = %{
          agent_id: agent_id,
          checkpoint_id: checkpoint_id,
          size: stat.size,
          created_at: stat.ctime |> DateTime.from_unix!(),
          modified_at: stat.mtime |> DateTime.from_unix!()
        }
        {:ok, metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_cleanup_old_checkpoints(state, max_age_days) do
    cutoff_time = System.os_time(:second) - (max_age_days * 24 * 60 * 60)
    count = cleanup_checkpoints_older_than(state.checkpoint_dir, cutoff_time)
    {:ok, count}
  rescue
    error -> {:error, error}
  end

  defp do_cleanup_agent_checkpoints(state, agent_id) do
    agent_dir = Path.join(state.checkpoint_dir, sanitize_filename(agent_id))
    File.rm_rf(agent_dir)
  end

  defp do_get_stats(state) do
    {total_checkpoints, total_size} = calculate_storage_stats(state.checkpoint_dir)

    %{
      total_checkpoints: total_checkpoints,
      total_agents: length(do_list_agents(state)),
      total_size: total_size,
      checkpoint_dir: state.checkpoint_dir
    }
  end

  defp get_checkpoint_path(state, agent_id, checkpoint_id) do
    agent_dir = Path.join(state.checkpoint_dir, sanitize_filename(agent_id))
    Path.join(agent_dir, "#{sanitize_filename(checkpoint_id)}.json")
  end

  defp add_metadata(data, agent_id, checkpoint_id) do
    metadata = %{
      agent_id: agent_id,
      checkpoint_id: checkpoint_id,
      saved_at: DateTime.utc_now(),
      version: "1.0"
    }

    Map.merge(data, %{__checkpoint_metadata__: metadata})
  end

  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[^a-zA-Z0-9_\-.]/, "_")
    |> String.trim_leading(".")
  end

  defp cleanup_checkpoints_older_than(dir, cutoff_time, count \\ 0) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, count, fn entry, acc ->
          entry_path = Path.join(dir, entry)

          cond do
            File.dir?(entry_path) ->
              cleanup_checkpoints_older_than(entry_path, cutoff_time, acc)

            String.ends_with?(entry, ".json") ->
              case File.stat(entry_path) do
                {:ok, stat} when stat.mtime < cutoff_time ->
                  File.rm(entry_path)
                  acc + 1

                _ ->
                  acc
              end

            true ->
              acc
          end
        end)

      {:error, _reason} ->
        count
    end
  end

  defp calculate_storage_stats(dir, {count, size} \\ {0, 0}) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, {count, size}, fn entry, {c, s} ->
          entry_path = Path.join(dir, entry)

          cond do
            File.dir?(entry_path) ->
              calculate_storage_stats(entry_path, {c, s})

            String.ends_with?(entry, ".json") ->
              case File.stat(entry_path) do
                {:ok, stat} -> {c + 1, s + stat.size}
                _ -> {c, s}
              end

            true ->
              {c, s}
          end
        end)

      {:error, _reason} ->
        {count, size}
    end
  end
end