defmodule Otto.AgentTest do
  use ExUnit.Case
  doctest Otto.Agent

  describe "agent lifecycle" do
    test "starts and stops an agent from YAML config" do
      # Test that we can start an agent from the helper.yaml config
      {:ok, agent} = Otto.Agent.start_agent("helper")
      assert is_pid(agent)

      # Test that we can stop the agent
      assert :ok = Otto.Agent.stop_agent(agent)
    end

    test "invokes an agent with a task" do
      {:ok, agent} = Otto.Agent.start_agent("helper")

      # Test basic invocation
      {:ok, result} = Otto.Agent.invoke(agent, "Test task")
      assert is_map(result)
      assert Map.has_key?(result, :content)

      Otto.Agent.stop_agent(agent)
    end

    test "gets agent status" do
      {:ok, agent} = Otto.Agent.start_agent("helper")

      {:ok, status} = Otto.Agent.get_status(agent)
      assert is_map(status)
      assert Map.has_key?(status, :state)
      assert Map.has_key?(status, :session_id)

      Otto.Agent.stop_agent(agent)
    end

    test "lists running agents" do
      {:ok, agent1} = Otto.Agent.start_agent("helper")
      {:ok, _agent2} = Otto.Agent.start_agent("helper")

      agents = Otto.Agent.list_agents()
      assert is_list(agents)
      assert length(agents) >= 2

      Otto.Agent.stop_agent(agent1)
    end
  end
end
