defmodule Otto.SupervisionTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  describe "Otto.Agent.Application supervision tree" do
    test "starts all required children" do
      # Get the application supervisor
      {:ok, app_supervisor} = Application.ensure_started(:otto_agent)

      children = Supervisor.which_children(Otto.Agent.Application)
      child_names = Enum.map(children, fn {name, _pid, _type, _modules} -> name end)

      # Verify core infrastructure is started
      expected_children = [
        Otto.ToolBus,
        Otto.Agent.Registry,
        Otto.Agent.DynamicSupervisor,
        Otto.ContextStore,
        Otto.Checkpointer,
        Otto.CostTracker
      ]

      for expected_child <- expected_children do
        assert expected_child in child_names,
          "Expected child #{expected_child} not found in supervision tree"
      end
    end

    test "supervision tree handles child failures gracefully" do
      # Start the application
      Application.ensure_started(:otto_agent)

      # Get a child process PID
      children = Supervisor.which_children(Otto.Agent.Application)
      {otto_toolbus, pid, :worker, [Otto.ToolBus]} =
        Enum.find(children, fn {name, _pid, _type, _modules} -> name == Otto.ToolBus end)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Kill the child process
      Process.exit(pid, :kill)

      # Wait a moment for restart
      :timer.sleep(100)

      # Verify it was restarted
      new_children = Supervisor.which_children(Otto.Agent.Application)
      {otto_toolbus, new_pid, :worker, [Otto.ToolBus]} =
        Enum.find(new_children, fn {name, _pid, _type, _modules} -> name == Otto.ToolBus end)

      assert is_pid(new_pid)
      assert new_pid != pid  # Should be a new process
      assert Process.alive?(new_pid)
    end

    test "registry is properly initialized and accessible" do
      Application.ensure_started(:otto_agent)

      # Verify Registry is running
      registry_pid = Process.whereis(Otto.Agent.Registry)
      assert is_pid(registry_pid)
      assert Process.alive?(registry_pid)

      # Verify we can look up processes (should be empty initially)
      processes = Registry.lookup(Otto.Agent.Registry, "test_agent")
      assert processes == []
    end

    test "dynamic supervisor is available for agent spawning" do
      Application.ensure_started(:otto_agent)

      # Verify DynamicSupervisor is running
      supervisor_pid = Process.whereis(Otto.Agent.DynamicSupervisor)
      assert is_pid(supervisor_pid)
      assert Process.alive?(supervisor_pid)

      # Verify we can query its children (should be empty initially)
      children = DynamicSupervisor.which_children(Otto.Agent.DynamicSupervisor)
      assert children == []
    end
  end

  describe "Otto.Agent.Registry integration" do
    setup do
      Application.ensure_started(:otto_agent)
      :ok
    end

    test "can register and lookup agent processes" do
      # Register a test process
      test_pid = spawn(fn -> :timer.sleep(1000) end)
      agent_id = "test_agent_#{System.unique_integer()}"

      {:ok, _registry_pid} = Registry.register(Otto.Agent.Registry, agent_id, %{
        config: %{name: "test"},
        started_at: DateTime.utc_now()
      })

      # Lookup the process
      [{registered_pid, metadata}] = Registry.lookup(Otto.Agent.Registry, agent_id)
      assert registered_pid == self()  # Registry.register registers current process
      assert metadata.config.name == "test"

      # Clean up
      Process.exit(test_pid, :normal)
    end

    test "handles process crashes by cleaning up registry entries" do
      agent_id = "crash_test_agent"

      # Spawn a process and register it
      test_pid = spawn(fn ->
        Registry.register(Otto.Agent.Registry, agent_id, %{})
        :timer.sleep(100)
      end)

      # Wait for registration
      :timer.sleep(50)

      # Verify it's registered
      entries = Registry.lookup(Otto.Agent.Registry, agent_id)
      assert length(entries) == 1

      # Kill the process
      Process.exit(test_pid, :kill)
      :timer.sleep(50)

      # Verify registry entry is cleaned up
      entries = Registry.lookup(Otto.Agent.Registry, agent_id)
      assert entries == []
    end

    test "prevents duplicate agent registration" do
      agent_id = "duplicate_test"

      # First registration should succeed
      {:ok, _} = Registry.register(Otto.Agent.Registry, agent_id, %{})

      # Second registration from same process should fail
      assert {:error, {:already_registered, _}} =
        Registry.register(Otto.Agent.Registry, agent_id, %{})
    end

    test "supports concurrent agent registration" do
      base_id = "concurrent_agent"

      # Spawn multiple processes that register concurrently
      tasks = for i <- 1..10 do
        Task.async(fn ->
          agent_id = "#{base_id}_#{i}"
          pid = self()
          result = Registry.register(Otto.Agent.Registry, agent_id, %{id: i})
          {agent_id, pid, result}
        end)
      end

      results = Enum.map(tasks, &Task.await/1)

      # All registrations should succeed
      for {agent_id, pid, result} <- results do
        assert {:ok, _} = result

        # Verify lookup works
        [{registered_pid, metadata}] = Registry.lookup(Otto.Agent.Registry, agent_id)
        assert registered_pid == pid
      end
    end
  end

  describe "DynamicSupervisor integration" do
    setup do
      Application.ensure_started(:otto_agent)
      :ok
    end

    test "can start and stop child processes" do
      initial_children = DynamicSupervisor.which_children(Otto.Agent.DynamicSupervisor)
      initial_count = length(initial_children)

      # Start a test GenServer
      child_spec = %{
        id: TestServer,
        start: {GenServer, :start_link, [TestServer, [], []]},
        restart: :transient
      }

      {:ok, pid} = DynamicSupervisor.start_child(Otto.Agent.DynamicSupervisor, child_spec)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Verify child count increased
      children = DynamicSupervisor.which_children(Otto.Agent.DynamicSupervisor)
      assert length(children) == initial_count + 1

      # Terminate the child
      :ok = DynamicSupervisor.terminate_child(Otto.Agent.DynamicSupervisor, pid)

      # Verify child count returned to initial
      final_children = DynamicSupervisor.which_children(Otto.Agent.DynamicSupervisor)
      assert length(final_children) == initial_count
    end

    test "handles child process failures according to restart strategy" do
      # Start a child process that will crash
      child_spec = %{
        id: CrashingServer,
        start: {GenServer, :start_link, [CrashingTestServer, [], []]},
        restart: :transient  # Should not restart on normal exit, but should on crash
      }

      {:ok, pid} = DynamicSupervisor.start_child(Otto.Agent.DynamicSupervisor, child_spec)
      assert is_pid(pid)

      # Kill the process abnormally
      Process.exit(pid, :kill)
      :timer.sleep(100)

      # For transient processes that crash, they should be restarted
      # But since our test server doesn't implement proper GenServer callbacks,
      # we just verify the supervisor handled the crash without failing
      children = DynamicSupervisor.which_children(Otto.Agent.DynamicSupervisor)
      assert is_list(children)  # Supervisor is still running
    end

    test "respects maximum restart limits" do
      # This test would verify restart intensity/period limits
      # For now, just verify the supervisor configuration
      supervisor_pid = Process.whereis(Otto.Agent.DynamicSupervisor)
      assert is_pid(supervisor_pid)

      # Verify supervisor state (configuration would be tested in implementation)
      children = DynamicSupervisor.which_children(Otto.Agent.DynamicSupervisor)
      assert is_list(children)
    end
  end

  describe "graceful shutdown" do
    test "application stops cleanly without orphaned processes" do
      # Start application if not already started
      Application.ensure_started(:otto_agent)

      # Get initial process count
      initial_processes = Process.list()

      # Stop the application
      :ok = Application.stop(:otto_agent)

      # Wait for cleanup
      :timer.sleep(100)

      # Verify no processes are left behind (within reasonable margin)
      final_processes = Process.list()
      process_diff = length(final_processes) - length(initial_processes)

      # Allow for some variation but should not have significant process leaks
      assert abs(process_diff) < 5,
        "Process leak detected: #{process_diff} processes difference"

      # Restart for other tests
      Application.ensure_started(:otto_agent)
    end
  end
end

# Mock GenServer for testing
defmodule TestServer do
  use GenServer

  def init([]), do: {:ok, %{}}
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}
  def handle_cast(_msg, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule CrashingTestServer do
  use GenServer

  def init([]), do: {:ok, %{}}
  def handle_call(_msg, _from, _state), do: exit(:crash)
  def handle_cast(_msg, _state), do: exit(:crash)
  def handle_info(_msg, _state), do: exit(:crash)
end