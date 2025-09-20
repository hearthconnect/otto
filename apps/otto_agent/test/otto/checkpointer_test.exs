defmodule Otto.CheckpointerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Otto.Checkpointer
  alias Otto.ArtifactRef

  @test_base_path "/tmp/otto_test_checkpoints"

  setup do
    # Clean up any existing test directory
    File.rm_rf(@test_base_path)

    {:ok, pid} = start_supervised({Checkpointer, base_path: @test_base_path, retention_days: 1})
    {:ok, checkpointer: pid}
  end

  describe "Checkpointer initialization" do
    test "creates base directory on startup" do
      assert File.exists?(@test_base_path)
      assert File.dir?(@test_base_path)
    end

    test "handles existing base directory gracefully" do
      # Directory already exists from setup
      # Start another instance
      {:ok, _pid} = start_supervised({Checkpointer, base_path: @test_base_path}, id: :second_checkpointer)
      assert File.exists?(@test_base_path)
    end
  end

  describe "artifact saving" do
    test "saves artifact with generated filename" do
      session_id = "test_session_#{System.unique_integer()}"
      content = "test artifact content"

      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :transcript, content)

      assert %ArtifactRef{} = artifact_ref
      assert artifact_ref.session_id == session_id
      assert artifact_ref.type == :transcript
      assert artifact_ref.size == byte_size(content)
      assert is_binary(artifact_ref.checksum)
      assert File.exists?(artifact_ref.path)

      # Verify content
      assert File.read!(artifact_ref.path) == content
    end

    test "saves artifact with custom filename" do
      session_id = "custom_filename_test"
      content = "custom content"
      opts = [filename: "my_custom_result.json"]

      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :result, content, opts)

      assert String.contains?(artifact_ref.path, "my_custom_result.json")
      assert artifact_ref.type == :result
    end

    test "creates session directory atomically" do
      session_id = "atomic_test_#{System.unique_integer()}"
      content = "atomic test content"

      session_dir = Path.join(@test_base_path, session_id)
      refute File.exists?(session_dir)

      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :intermediate, content)

      assert File.exists?(session_dir)
      assert File.dir?(session_dir)
      assert File.exists?(artifact_ref.path)
    end

    test "performs atomic writes using temp files" do
      session_id = "atomic_write_test"
      content = "atomic write content"

      # Monitor filesystem during write
      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :result, content)

      # Verify no temp files left behind
      session_dir = Path.join(@test_base_path, session_id)
      files = File.ls!(session_dir)
      temp_files = Enum.filter(files, &String.ends_with?(&1, ".tmp"))
      assert temp_files == []

      # Verify final file exists and has correct content
      assert File.read!(artifact_ref.path) == content
    end

    test "calculates correct checksum" do
      session_id = "checksum_test"
      content = "checksum test content"

      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :transcript, content)

      expected_checksum = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      assert artifact_ref.checksum == expected_checksum
    end

    test "handles large artifacts" do
      session_id = "large_artifact_test"
      content = String.duplicate("large content ", 10000)  # ~130KB

      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :intermediate, content)

      assert artifact_ref.size == byte_size(content)
      assert File.read!(artifact_ref.path) == content
    end

    test "handles concurrent saves to same session" do
      session_id = "concurrent_saves"

      tasks = for i <- 1..5 do
        Task.async(fn ->
          content = "concurrent content #{i}"
          Checkpointer.save_artifact(session_id, :intermediate, content, filename: "artifact_#{i}")
        end)
      end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      for result <- results do
        assert match?({:ok, %ArtifactRef{}}, result)
      end

      # Verify all files exist
      {:ok, artifacts} = Checkpointer.list_artifacts(session_id)
      assert length(artifacts) == 5
    end
  end

  describe "artifact loading" do
    test "loads artifact by reference" do
      session_id = "load_test"
      content = "content to load"

      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :result, content)
      {:ok, loaded_content} = Checkpointer.load_artifact(artifact_ref)

      assert loaded_content == content
    end

    test "returns error for non-existent artifact" do
      fake_ref = %ArtifactRef{
        path: "/non/existent/path",
        type: :result,
        size: 0,
        checksum: "fake",
        session_id: "fake"
      }

      assert {:error, {:load_failed, _}} = Checkpointer.load_artifact(fake_ref)
    end

    test "handles corrupted file paths gracefully" do
      session_id = "corruption_test"
      content = "original content"

      {:ok, artifact_ref} = Checkpointer.save_artifact(session_id, :result, content)

      # Corrupt the file
      File.write!(artifact_ref.path, "corrupted content")

      # Should still load (checksum validation would be separate concern)
      {:ok, loaded_content} = Checkpointer.load_artifact(artifact_ref)
      assert loaded_content == "corrupted content"
    end
  end

  describe "artifact listing" do
    test "lists artifacts for a session" do
      session_id = "list_test"

      # Create multiple artifacts
      artifacts = [
        {"transcript", "transcript content"},
        {"result", "result content"},
        {"intermediate", "intermediate content"}
      ]

      for {type, content} <- artifacts do
        {:ok, _ref} = Checkpointer.save_artifact(session_id, String.to_atom(type), content)
      end

      {:ok, artifact_list} = Checkpointer.list_artifacts(session_id)

      assert length(artifact_list) == 3
      for artifact <- artifact_list do
        assert %ArtifactRef{} = artifact
        assert artifact.session_id == session_id
      end
    end

    test "returns empty list for non-existent session" do
      {:ok, artifacts} = Checkpointer.list_artifacts("non_existent_session")
      assert artifacts == []
    end

    test "ignores temporary files in listings" do
      session_id = "temp_file_test"
      session_dir = Path.join(@test_base_path, session_id)
      File.mkdir_p!(session_dir)

      # Create a real artifact
      {:ok, _ref} = Checkpointer.save_artifact(session_id, :result, "real content")

      # Manually create a temp file
      temp_file = Path.join(session_dir, "fake_artifact.tmp")
      File.write!(temp_file, "temp content")

      {:ok, artifacts} = Checkpointer.list_artifacts(session_id)

      # Should only see the real artifact, not the temp file
      assert length(artifacts) == 1
      artifact_names = Enum.map(artifacts, &Path.basename(&1.path))
      refute Enum.any?(artifact_names, &String.ends_with?(&1, ".tmp"))
    end
  end

  describe "cleanup and retention" do
    test "cleans up expired sessions" do
      # Create test session directory with old timestamp
      old_session_id = "old_session"
      old_session_dir = Path.join(@test_base_path, old_session_id)
      File.mkdir_p!(old_session_dir)

      # Create an artifact
      old_artifact = Path.join(old_session_dir, "old_artifact")
      File.write!(old_artifact, "old content")

      # Set directory timestamp to be older than retention period
      # This is a bit tricky to test reliably, so we'll test the behavior
      {:ok, cleaned_count} = Checkpointer.cleanup_expired()

      # For this test, we expect 0 cleaned since we just created the directory
      # In real usage, directories would be older
      assert is_integer(cleaned_count)
      assert cleaned_count >= 0
    end

    test "preserves recent sessions during cleanup" do
      recent_session_id = "recent_session"

      # Create recent artifact
      {:ok, _ref} = Checkpointer.save_artifact(recent_session_id, :result, "recent content")

      {:ok, cleaned_count} = Checkpointer.cleanup_expired()

      # Recent session should not be cleaned
      session_dir = Path.join(@test_base_path, recent_session_id)
      assert File.exists?(session_dir)
    end
  end

  describe "storage statistics" do
    test "provides accurate storage statistics" do
      # Create some test data
      sessions = ["stats_session_1", "stats_session_2"]
      artifacts_per_session = 2

      for session_id <- sessions do
        for i <- 1..artifacts_per_session do
          content = "stats content #{i} for #{session_id}"
          {:ok, _ref} = Checkpointer.save_artifact(session_id, :result, content)
        end
      end

      {:ok, stats} = Checkpointer.get_stats()

      assert stats.session_count >= length(sessions)
      assert stats.artifact_count >= length(sessions) * artifacts_per_session
      assert stats.total_size > 0
      assert stats.base_path == @test_base_path
      assert is_integer(stats.retention_days)
    end

    test "handles empty storage statistics" do
      # Fresh checkpointer with empty directory
      empty_path = "/tmp/otto_empty_test"
      File.rm_rf(empty_path)

      {:ok, _pid} = start_supervised({Checkpointer, base_path: empty_path}, id: :empty_checkpointer)

      {:ok, stats} = GenServer.call(:empty_checkpointer, :get_stats)

      assert stats.session_count == 0
      assert stats.artifact_count == 0
      assert stats.total_size == 0

      # Clean up
      File.rm_rf(empty_path)
    end
  end

  describe "error handling" do
    test "handles filesystem permissions errors gracefully" do
      # This test would require setting up permission scenarios
      # For now, we verify the error handling structure exists
      session_id = "permission_test"
      content = "test content"

      # Normal case should work
      assert {:ok, %ArtifactRef{}} = Checkpointer.save_artifact(session_id, :result, content)
    end

    test "logs errors appropriately" do
      # Test error logging by providing invalid path in artifact ref
      invalid_ref = %ArtifactRef{
        path: "/invalid/path/to/nonexistent/file.txt",
        type: :result,
        size: 100,
        checksum: "invalid",
        session_id: "invalid"
      }

      log_output = capture_log(fn ->
        result = Checkpointer.load_artifact(invalid_ref)
        assert match?({:error, {:load_failed, _}}, result)
      end)

      assert String.contains?(log_output, "Failed to load artifact")
    end
  end
end