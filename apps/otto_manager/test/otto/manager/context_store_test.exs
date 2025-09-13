defmodule Otto.Manager.ContextStoreTest do
  use ExUnit.Case, async: true

  alias Otto.Manager.ContextStore

  setup do
    {:ok, pid} = ContextStore.start_link(name: :"test_context_store_#{:rand.uniform(1000)}")
    {:ok, store: pid}
  end

  describe "context storage" do
    test "stores and retrieves context data", %{store: store} do
      context_data = %{
        session_id: "session_123",
        agent_id: "agent_456",
        messages: [%{role: "user", content: "Hello"}],
        tools_used: ["file_read"],
        metadata: %{start_time: DateTime.utc_now()}
      }

      assert :ok = ContextStore.put(store, "session_123", context_data)
      assert {:ok, ^context_data} = ContextStore.get(store, "session_123")
    end

    test "returns error for non-existent context", %{store: store} do
      assert {:error, :not_found} = ContextStore.get(store, "non_existent")
    end

    test "updates existing context", %{store: store} do
      initial_data = %{messages: [%{role: "user", content: "Hello"}]}
      updated_data = %{messages: [%{role: "user", content: "Updated"}]}

      :ok = ContextStore.put(store, "session_123", initial_data)
      assert :ok = ContextStore.put(store, "session_123", updated_data)
      assert {:ok, ^updated_data} = ContextStore.get(store, "session_123")
    end

    test "deletes context", %{store: store} do
      context_data = %{session_id: "session_123"}

      :ok = ContextStore.put(store, "session_123", context_data)
      assert :ok = ContextStore.delete(store, "session_123")
      assert {:error, :not_found} = ContextStore.get(store, "session_123")
    end

    test "lists all context keys", %{store: store} do
      :ok = ContextStore.put(store, "session_1", %{data: "test1"})
      :ok = ContextStore.put(store, "session_2", %{data: "test2"})

      keys = ContextStore.list_keys(store)
      assert "session_1" in keys
      assert "session_2" in keys
      assert length(keys) == 2
    end
  end

  describe "context manipulation" do
    test "appends to list field", %{store: store} do
      initial_data = %{messages: [%{role: "user", content: "Hello"}]}
      new_message = %{role: "assistant", content: "Hi there!"}

      :ok = ContextStore.put(store, "session_123", initial_data)
      assert :ok = ContextStore.append_to_list(store, "session_123", :messages, new_message)

      {:ok, updated_data} = ContextStore.get(store, "session_123")
      assert length(updated_data.messages) == 2
      assert List.last(updated_data.messages) == new_message
    end

    test "appends to list creates field if not exists", %{store: store} do
      initial_data = %{session_id: "session_123"}
      new_message = %{role: "user", content: "Hello"}

      :ok = ContextStore.put(store, "session_123", initial_data)
      assert :ok = ContextStore.append_to_list(store, "session_123", :messages, new_message)

      {:ok, updated_data} = ContextStore.get(store, "session_123")
      assert updated_data.messages == [new_message]
    end

    test "updates nested field", %{store: store} do
      initial_data = %{
        session_id: "session_123",
        metadata: %{start_time: DateTime.utc_now()}
      }

      :ok = ContextStore.put(store, "session_123", initial_data)
      assert :ok = ContextStore.update_field(store, "session_123", [:metadata, :end_time], DateTime.utc_now())

      {:ok, updated_data} = ContextStore.get(store, "session_123")
      assert Map.has_key?(updated_data.metadata, :end_time)
    end
  end

  describe "cleanup and expiration" do
    test "cleans up expired contexts", %{store: store} do
      # Put some data with custom expiration
      :ok = ContextStore.put(store, "session_1", %{data: "test"}, ttl: 50)
      :ok = ContextStore.put(store, "session_2", %{data: "test"}, ttl: 5000)

      # Wait for first to expire
      Process.sleep(100)

      # Force cleanup
      ContextStore.cleanup_expired(store)

      # First should be gone, second should remain
      assert {:error, :not_found} = ContextStore.get(store, "session_1")
      assert {:ok, %{data: "test"}} = ContextStore.get(store, "session_2")
    end

    test "clears all contexts", %{store: store} do
      :ok = ContextStore.put(store, "session_1", %{data: "test1"})
      :ok = ContextStore.put(store, "session_2", %{data: "test2"})

      assert :ok = ContextStore.clear_all(store)
      assert [] = ContextStore.list_keys(store)
    end

    test "gets statistics", %{store: store} do
      :ok = ContextStore.put(store, "session_1", %{data: "test1"})
      :ok = ContextStore.put(store, "session_2", %{data: "test2"})

      stats = ContextStore.get_stats(store)
      assert stats.total_contexts == 2
      assert is_integer(stats.memory_usage)
      assert is_integer(stats.table_size)
    end
  end
end