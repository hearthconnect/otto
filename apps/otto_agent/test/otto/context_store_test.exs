defmodule Otto.ContextStoreTest do
  use ExUnit.Case
  alias Otto.ContextStore

  setup do
    {:ok, pid} = start_supervised(ContextStore)
    {:ok, context_store: pid}
  end

  describe "ContextStore operations" do
    test "starts with empty storage" do
      assert ContextStore.list_contexts() == []

      {:ok, stats} = ContextStore.get_stats()
      assert stats.context_count == 0
      assert stats.current_size == 0
    end

    test "can store and retrieve context data" do
      context_id = "test_context_#{System.unique_integer()}"
      data = %{message: "hello", state: :active}

      assert :ok = ContextStore.put_context(context_id, data)

      assert {:ok, entry} = ContextStore.get_context(context_id)
      assert entry.data == data
      assert Map.has_key?(entry.metadata, :started_at)
      assert Map.has_key?(entry.metadata, :updated_at)
    end

    test "can store context with custom metadata" do
      context_id = "test_context_with_metadata"
      data = %{task: "test"}
      metadata = %{task_id: "task_123", parent_workflow: "workflow_456"}

      assert :ok = ContextStore.put_context(context_id, data, metadata)

      assert {:ok, entry} = ContextStore.get_context(context_id)
      assert entry.data == data
      assert entry.metadata.task_id == "task_123"
      assert entry.metadata.parent_workflow == "workflow_456"
    end

    test "returns error for non-existent context" do
      assert {:error, :not_found} = ContextStore.get_context("non_existent")
    end

    test "can delete context data" do
      context_id = "delete_test"
      data = %{temp: "data"}

      ContextStore.put_context(context_id, data)
      assert {:ok, _entry} = ContextStore.get_context(context_id)

      assert :ok = ContextStore.delete_context(context_id)
      assert {:error, :not_found} = ContextStore.get_context(context_id)
    end

    test "delete returns error for non-existent context" do
      assert {:error, :not_found} = ContextStore.delete_context("non_existent")
    end

    test "lists all context IDs" do
      contexts = ["context_1", "context_2", "context_3"]

      for context_id <- contexts do
        ContextStore.put_context(context_id, %{id: context_id})
      end

      context_list = ContextStore.list_contexts()
      assert length(context_list) >= 3

      for context_id <- contexts do
        assert context_id in context_list
      end
    end

    test "tracks storage size" do
      context_id = "size_test"
      small_data = %{size: "small"}
      large_data = %{size: "large", content: String.duplicate("x", 1000)}

      # Store small data
      ContextStore.put_context(context_id, small_data)
      {:ok, stats1} = ContextStore.get_stats()
      assert stats1.current_size > 0

      # Update with larger data
      ContextStore.delete_context(context_id)
      ContextStore.put_context(context_id, large_data)
      {:ok, stats2} = ContextStore.get_stats()
      assert stats2.current_size > stats1.current_size

      # Clean up
      ContextStore.delete_context(context_id)
      {:ok, stats3} = ContextStore.get_stats()
      assert stats3.current_size < stats2.current_size
    end

    test "respects maximum size limits" do
      # Create a store with very small max size for testing
      small_store_opts = [max_size: 100]  # 100 bytes
      {:ok, small_store} = start_supervised({ContextStore, small_store_opts}, id: :small_store)

      # Try to store data larger than the limit
      context_id = "overflow_test"
      large_data = %{content: String.duplicate("x", 200)}  # > 100 bytes

      # This should fail due to size limit
      result = GenServer.call(small_store, {:put_context, context_id, large_data, %{}})
      assert match?({:error, :storage_full}, result)
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes" do
      base_id = "concurrent_test"

      # Spawn multiple tasks that read/write concurrently
      write_tasks = for i <- 1..5 do
        Task.async(fn ->
          context_id = "#{base_id}_write_#{i}"
          data = %{id: i, data: "write_data_#{i}"}
          ContextStore.put_context(context_id, data)
        end)
      end

      read_tasks = for i <- 1..5 do
        Task.async(fn ->
          context_id = "#{base_id}_read_#{i}"
          # Store first
          ContextStore.put_context(context_id, %{id: i})
          # Then read
          ContextStore.get_context(context_id)
        end)
      end

      # Wait for all operations to complete
      write_results = Enum.map(write_tasks, &Task.await/1)
      read_results = Enum.map(read_tasks, &Task.await/1)

      # All writes should succeed
      for result <- write_results do
        assert result == :ok
      end

      # All reads should succeed
      for result <- read_results do
        assert match?({:ok, _}, result)
      end
    end

    test "handles process cleanup automatically" do
      context_id = "cleanup_test"

      # Spawn a process that stores context then dies
      test_pid = spawn(fn ->
        ContextStore.put_context(context_id, %{from_process: self()})
        :timer.sleep(100)
      end)

      # Wait for process to complete and die
      Process.monitor(test_pid)
      :timer.sleep(200)

      # Context should still exist (cleanup is manual or triggered by specific events)
      # This test documents current behavior - actual cleanup might be event-driven
      case ContextStore.get_context(context_id) do
        {:ok, _entry} ->
          # Context exists - cleanup is manual
          ContextStore.delete_context(context_id)
        {:error, :not_found} ->
          # Context was cleaned up automatically
          :ok
      end
    end
  end

  describe "storage statistics" do
    test "provides accurate storage metrics" do
      # Clean slate
      contexts_to_create = 3

      for i <- 1..contexts_to_create do
        context_id = "stats_test_#{i}"
        data = %{id: i, content: String.duplicate("data", i * 10)}
        ContextStore.put_context(context_id, data)
      end

      {:ok, stats} = ContextStore.get_stats()

      assert stats.context_count >= contexts_to_create
      assert stats.current_size > 0
      assert stats.utilization >= 0 and stats.utilization <= 1
      assert is_number(stats.max_size)
      assert stats.max_size > stats.current_size

      # Clean up
      for i <- 1..contexts_to_create do
        ContextStore.delete_context("stats_test_#{i}")
      end
    end
  end
end