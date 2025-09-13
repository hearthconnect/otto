defmodule Otto.Manager.CheckpointerTest do
  use ExUnit.Case, async: true

  alias Otto.Manager.Checkpointer

  @temp_dir "/tmp/otto_test_checkpoints"

  setup do
    # Create temp directory for testing
    File.mkdir_p!(@temp_dir)

    {:ok, pid} = Checkpointer.start_link(
      name: :"test_checkpointer_#{:rand.uniform(1000)}",
      checkpoint_dir: @temp_dir
    )

    on_exit(fn ->
      # Clean up temp directory
      File.rm_rf(@temp_dir)
    end)

    {:ok, checkpointer: pid}
  end

  describe "checkpoint operations" do
    test "saves and loads checkpoints", %{checkpointer: checkpointer} do
      checkpoint_data = %{
        agent_id: "agent_123",
        session_id: "session_456",
        state: %{
          current_task: "analyzing code",
          tools_used: ["file_read", "grep"],
          context: %{messages: [%{role: "user", content: "Hello"}]}
        },
        timestamp: DateTime.utc_now()
      }

      assert :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", checkpoint_data)
      assert {:ok, loaded_data} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "checkpoint_1")

      # Compare relevant fields (timestamp might have slight differences due to serialization)
      assert loaded_data.agent_id == checkpoint_data.agent_id
      assert loaded_data.session_id == checkpoint_data.session_id
      assert loaded_data.state == checkpoint_data.state
    end

    test "returns error for non-existent checkpoint", %{checkpointer: checkpointer} do
      assert {:error, :not_found} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "non_existent")
    end

    test "overwrites existing checkpoint", %{checkpointer: checkpointer} do
      initial_data = %{state: %{step: 1}}
      updated_data = %{state: %{step: 2}}

      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", initial_data)
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", updated_data)

      {:ok, loaded_data} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "checkpoint_1")
      assert loaded_data.state.step == 2
    end

    test "deletes checkpoint", %{checkpointer: checkpointer} do
      checkpoint_data = %{state: %{step: 1}}

      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", checkpoint_data)
      assert :ok = Checkpointer.delete_checkpoint(checkpointer, "agent_123", "checkpoint_1")
      assert {:error, :not_found} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "checkpoint_1")
    end
  end

  describe "checkpoint listing" do
    test "lists checkpoints for an agent", %{checkpointer: checkpointer} do
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", %{step: 1})
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_2", %{step: 2})
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_456", "checkpoint_1", %{step: 1})

      checkpoints = Checkpointer.list_checkpoints(checkpointer, "agent_123")
      assert "checkpoint_1" in checkpoints
      assert "checkpoint_2" in checkpoints
      assert length(checkpoints) == 2
    end

    test "lists all agents with checkpoints", %{checkpointer: checkpointer} do
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", %{step: 1})
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_456", "checkpoint_1", %{step: 1})

      agents = Checkpointer.list_agents(checkpointer)
      assert "agent_123" in agents
      assert "agent_456" in agents
      assert length(agents) == 2
    end

    test "gets checkpoint metadata", %{checkpointer: checkpointer} do
      checkpoint_data = %{state: %{step: 1}}
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", checkpoint_data)

      {:ok, metadata} = Checkpointer.get_checkpoint_metadata(checkpointer, "agent_123", "checkpoint_1")

      assert metadata.agent_id == "agent_123"
      assert metadata.checkpoint_id == "checkpoint_1"
      assert is_integer(metadata.size)
      assert %DateTime{} = metadata.created_at
      assert %DateTime{} = metadata.modified_at
    end
  end

  describe "cleanup operations" do
    test "cleans up old checkpoints", %{checkpointer: checkpointer} do
      # Save some checkpoints
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "old_checkpoint", %{step: 1})
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "new_checkpoint", %{step: 2})

      # Manually set old timestamp by modifying the file
      old_checkpoint_path = Path.join([@temp_dir, "agent_123", "old_checkpoint.json"])
      # Touch file to set old timestamp (more than 7 days ago)
      old_time = System.os_time(:second) - (8 * 24 * 60 * 60)  # 8 days ago
      File.touch!(old_checkpoint_path, old_time)

      # Run cleanup
      {:ok, cleaned_count} = Checkpointer.cleanup_old_checkpoints(checkpointer, max_age_days: 7)

      assert cleaned_count >= 1
      assert {:error, :not_found} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "old_checkpoint")
      assert {:ok, _} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "new_checkpoint")
    end

    test "cleans up checkpoints for specific agent", %{checkpointer: checkpointer} do
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", %{step: 1})
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_2", %{step: 2})
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_456", "checkpoint_1", %{step: 1})

      assert :ok = Checkpointer.cleanup_agent_checkpoints(checkpointer, "agent_123")

      assert {:error, :not_found} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "checkpoint_1")
      assert {:error, :not_found} = Checkpointer.load_checkpoint(checkpointer, "agent_123", "checkpoint_2")
      assert {:ok, _} = Checkpointer.load_checkpoint(checkpointer, "agent_456", "checkpoint_1")
    end
  end

  describe "error handling" do
    test "handles filesystem errors gracefully", %{checkpointer: checkpointer} do
      # Try to save to a location that will fail (invalid characters)
      invalid_agent_id = "agent/with/slashes"
      result = Checkpointer.save_checkpoint(checkpointer, invalid_agent_id, "checkpoint_1", %{step: 1})

      # Should handle the error gracefully
      assert {:error, _reason} = result
    end
  end

  describe "statistics" do
    test "gets storage statistics", %{checkpointer: checkpointer} do
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_123", "checkpoint_1", %{data: "test"})
      :ok = Checkpointer.save_checkpoint(checkpointer, "agent_456", "checkpoint_1", %{data: "test"})

      stats = Checkpointer.get_stats(checkpointer)

      assert stats.total_checkpoints >= 2
      assert stats.total_agents >= 2
      assert is_integer(stats.total_size)
      assert is_binary(stats.checkpoint_dir)
    end
  end
end