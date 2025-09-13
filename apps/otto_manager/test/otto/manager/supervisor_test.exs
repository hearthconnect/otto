defmodule Otto.Manager.SupervisorTest do
  use ExUnit.Case, async: true

  alias Otto.Manager.Supervisor, as: ManagerSupervisor

  describe "supervision tree" do
    test "starts with all required children" do
      {:ok, sup_pid} = ManagerSupervisor.start_link(name: :"test_sup_#{:rand.uniform(1000)}")

      children = Supervisor.which_children(sup_pid)
      child_names = Enum.map(children, fn {name, _pid, _type, _modules} -> name end)

      assert Otto.Registry in child_names
      assert Otto.Tool.Bus in child_names
      assert Otto.Manager.ContextStore in child_names
      assert Otto.Manager.Checkpointer in child_names
      assert Otto.Manager.CostTracker in child_names
      assert Otto.Manager.DynamicSupervisor in child_names
      assert Otto.Manager.TaskSupervisor in child_names

      # Clean up
      Supervisor.stop(sup_pid)
    end

    test "registry is available for process naming" do
      {:ok, sup_pid} = ManagerSupervisor.start_link(name: :"test_sup_#{:rand.uniform(1000)}")

      # Registry should be running and accessible
      assert Process.whereis(Otto.Registry) != nil

      # Clean up
      Supervisor.stop(sup_pid)
    end

    test "restarts failed children" do
      {:ok, sup_pid} = ManagerSupervisor.start_link(name: :"test_sup_#{:rand.uniform(1000)}")

      # Get the Tool Bus child
      children = Supervisor.which_children(sup_pid)
      {_name, tool_bus_pid, _type, _modules} = Enum.find(children, fn {name, _pid, _type, _modules} ->
        name == Otto.Tool.Bus
      end)

      # Kill the Tool Bus
      Process.exit(tool_bus_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Verify it's been restarted
      new_children = Supervisor.which_children(sup_pid)
      {_name, new_tool_bus_pid, _type, _modules} = Enum.find(new_children, fn {name, _pid, _type, _modules} ->
        name == Otto.Tool.Bus
      end)

      assert new_tool_bus_pid != tool_bus_pid
      assert Process.alive?(new_tool_bus_pid)

      # Clean up
      Supervisor.stop(sup_pid)
    end
  end

  describe "child specs" do
    test "provides correct child specifications" do
      child_specs = ManagerSupervisor.child_specs()

      assert length(child_specs) == 7

      # Verify each child spec has required fields
      Enum.each(child_specs, fn child_spec ->
        assert Map.has_key?(child_spec, :id)
        assert Map.has_key?(child_spec, :start)
        assert Map.has_key?(child_spec, :type)
      end)
    end
  end
end