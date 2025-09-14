defmodule Otto.Manager.SupervisorTest do
  use ExUnit.Case, async: true

  alias Otto.Manager.Supervisor, as: ManagerSupervisor

  describe "supervision tree" do
    test "starts with all required children" do
      # Use the already-running supervisor from the application
      sup_pid = Process.whereis(Otto.Manager.Application.Supervisor)
      assert sup_pid != nil

      children = Supervisor.which_children(sup_pid)
      child_names = Enum.map(children, fn {name, _pid, _type, _modules} -> name end)

      assert Otto.Registry in child_names
      assert Otto.Tool.Bus in child_names
      assert Otto.Manager.ContextStore in child_names
      assert Otto.Manager.Checkpointer in child_names
      assert Otto.Manager.CostTracker in child_names
      assert Otto.Manager.DynamicSupervisor in child_names
      assert Otto.Manager.TaskSupervisor in child_names
    end

    test "registry is available for process naming" do
      # Registry should already be running from application start
      assert Process.whereis(Otto.Registry) != nil
    end

    test "restarts failed children" do
      # Use the already-running supervisor from the application
      sup_pid = Process.whereis(Otto.Manager.Application.Supervisor)
      assert sup_pid != nil

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
    end
  end

  describe "child specs" do
    test "provides correct child specifications" do
      child_specs = ManagerSupervisor.child_specs()

      assert length(child_specs) == 7

      # Verify each child spec is valid (can be tuples or maps)
      Enum.each(child_specs, fn child_spec ->
        # Child specs can be tuples like {module, args} or maps
        assert is_tuple(child_spec) or is_map(child_spec)

        # If it's a tuple, verify it has at least module
        if is_tuple(child_spec) do
          assert tuple_size(child_spec) >= 1
          assert is_atom(elem(child_spec, 0))
        end

        # If it's a map, verify required fields
        if is_map(child_spec) do
          assert Map.has_key?(child_spec, :id)
          assert Map.has_key?(child_spec, :start)
        end
      end)
    end
  end
end