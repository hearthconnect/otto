defmodule Otto.Agent.LLMIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  describe "LLM integration" do
    test "agent provides intelligent responses instead of echo" do
      {:ok, agent} = Otto.Agent.start_agent("helper")

      # Ask a question that requires knowledge/reasoning
      {:ok, result} = Otto.Agent.invoke(agent, "What is 2 + 2?")

      # Verify it's not an echo response
      refute String.contains?(result.content, "Agent helper received:")

      # Verify it contains an intelligent response
      assert String.contains?(String.downcase(result.content), "4") or
             String.contains?(String.downcase(result.content), "four")

      # Verify we have real token usage
      assert result.cost.tokens_used > 0
      assert result.cost.cost_used > 0

      Otto.Agent.stop_agent(agent)
    end

    test "agent uses system prompt correctly" do
      {:ok, agent} = Otto.Agent.start_agent("helper")

      # Ask for code help to trigger coding assistant behavior
      {:ok, result} = Otto.Agent.invoke(agent, "Write a simple hello function in Python")

      # Should respond as a coding assistant
      response_lower = String.downcase(result.content)
      assert String.contains?(response_lower, "def") or
             String.contains?(response_lower, "function") or
             String.contains?(response_lower, "python")

      Otto.Agent.stop_agent(agent)
    end

    test "agent maintains conversation context" do
      {:ok, agent} = Otto.Agent.start_agent("helper")

      # First message
      {:ok, result1} = Otto.Agent.invoke(agent, "My favorite color is blue.")

      # Follow-up that requires remembering context
      {:ok, result2} = Otto.Agent.invoke(agent, "What color did I just say I like?")

      # Should remember blue from previous message
      assert String.contains?(String.downcase(result2.content), "blue")

      Otto.Agent.stop_agent(agent)
    end

    test "agent handles errors gracefully when LLM fails" do
      # This test would require mocking LLM failure, but demonstrates the concept
      {:ok, agent} = Otto.Agent.start_agent("helper")

      # Even with potential failures, agent should not crash
      {:ok, result} = Otto.Agent.invoke(agent, "Hello")

      # Should get some kind of response (either success or error message)
      assert is_binary(result.content)
      assert byte_size(result.content) > 0

      Otto.Agent.stop_agent(agent)
    end

    test "budget tracking works with real token usage" do
      {:ok, agent} = Otto.Agent.start_agent("helper")

      # Multiple requests to accumulate tokens
      {:ok, result1} = Otto.Agent.invoke(agent, "Hello")
      {:ok, result2} = Otto.Agent.invoke(agent, "What's the weather like?")

      # Should accumulate real token usage
      total_tokens = result1.cost.tokens_used + result2.cost.tokens_used
      total_cost = result1.cost.cost_used + result2.cost.cost_used

      assert total_tokens > 0
      assert total_cost > 0

      # Second request should show accumulated usage is higher
      assert result2.cost.tokens_used >= result1.cost.tokens_used

      Otto.Agent.stop_agent(agent)
    end
  end
end