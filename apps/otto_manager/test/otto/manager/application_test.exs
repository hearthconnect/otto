defmodule Otto.Manager.ApplicationTest do
  use ExUnit.Case, async: false

  describe "application startup" do
    test "core processes are running" do
      # Verify core processes are running (they should already be started by the application)
      assert Process.whereis(Otto.Registry) != nil
      assert Process.whereis(Otto.Tool.Bus) != nil
      assert Process.whereis(Otto.Manager.ContextStore) != nil
      assert Process.whereis(Otto.Manager.Checkpointer) != nil
      assert Process.whereis(Otto.Manager.CostTracker) != nil
      assert Process.whereis(Otto.Manager.DynamicSupervisor) != nil
      assert Process.whereis(Otto.Manager.TaskSupervisor) != nil

      # Test basic functionality - just verify we can interact with the processes
      tools = Otto.Tool.Bus.list_tools(Otto.Tool.Bus)
      assert is_list(tools)

      stats = Otto.Manager.CostTracker.get_global_stats(Otto.Manager.CostTracker)
      assert is_map(stats)

      context_keys = Otto.Manager.ContextStore.list_keys(Otto.Manager.ContextStore)
      assert is_list(context_keys)
    end
  end
end