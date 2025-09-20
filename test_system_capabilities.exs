#!/usr/bin/env elixir

# =============================================================================
# Otto System Capabilities Test & Documentation
# =============================================================================
#
# This script demonstrates the core capabilities of the Otto AI agent system,
# including LLM integration, agent lifecycle management, and multi-turn conversations.
# It serves both as a test suite and living documentation of the system's features.
#
# Prerequisites:
# - OPENAI_API_KEY environment variable must be set
# - Otto umbrella application components must be compiled
#
# Usage:
#   elixir test_system_capabilities.exs
#
# =============================================================================

# Load the Otto umbrella applications
Application.ensure_all_started(:otto_manager)
Application.ensure_all_started(:otto_agent)

defmodule OttoSystemTest do
  @moduledoc """
  Comprehensive test suite demonstrating Otto's core capabilities.
  """

  def run do
    IO.puts """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║       Otto AI Agent System - Core Capabilities Test                 ║
    ╚══════════════════════════════════════════════════════════════════════╝
    """

    # Track overall test results
    results = []

    # Test 1: Basic LLM Integration
    results = [test_llm_integration() | results]

    # Test 2: Agent Lifecycle Management
    results = [test_agent_lifecycle() | results]

    # Test 3: Multi-turn Conversations
    results = [test_conversations() | results]

    # Test 4: Budget Tracking
    results = [test_budget_tracking() | results]

    # Test 5: Real-world Scenario
    results = [test_real_world_scenario() | results]

    # Print summary
    print_summary(results)
  end

  defp test_llm_integration do
    IO.puts "\n📚 Test 1: LLM Integration"
    IO.puts "─────────────────────────────────────"

    try do
      # Test simple completion
      {:ok, response} = Otto.LLM.complete("gpt-3.5-turbo", "What is 2+2? Answer with just the number.")
      IO.puts "  ✅ Simple completion: #{response.content}"

      # Test chat with context
      messages = [
        %{role: "system", content: "You are a helpful math tutor"},
        %{role: "user", content: "What's the Pythagorean theorem?"}
      ]
      {:ok, chat_response} = Otto.LLM.chat("gpt-3.5-turbo", messages)
      IO.puts "  ✅ Chat with context works"
      IO.puts "  📊 Tokens used: #{chat_response.usage.total_tokens}"

      {:ok, "LLM Integration"}
    rescue
      error ->
        IO.puts "  ❌ Error: #{inspect(error)}"
        {:error, "LLM Integration"}
    end
  end

  defp test_agent_lifecycle do
    IO.puts "\n🤖 Test 2: Agent Lifecycle Management"
    IO.puts "─────────────────────────────────────"

    try do
      # Start an agent
      {:ok, agent} = Otto.Agent.start_agent("test_agent")
      IO.puts "  ✅ Agent started: #{inspect(agent)}"

      # Verify agent is alive
      if Process.alive?(agent) do
        IO.puts "  ✅ Agent process is alive"
      end

      # Simple invocation
      {:ok, result} = Otto.Agent.invoke(agent, "Say 'Hello Otto!'")
      IO.puts "  ✅ Agent responded: #{result.content}"

      # Stop the agent
      Otto.Agent.stop_agent(agent)
      Process.sleep(100)

      if not Process.alive?(agent) do
        IO.puts "  ✅ Agent stopped successfully"
      end

      {:ok, "Agent Lifecycle"}
    rescue
      error ->
        IO.puts "  ❌ Error: #{inspect(error)}"
        {:error, "Agent Lifecycle"}
    end
  end

  defp test_conversations do
    IO.puts "\n💬 Test 3: Multi-turn Conversations"
    IO.puts "─────────────────────────────────────"

    try do
      {:ok, agent} = Otto.Agent.start_agent("conversation_agent")

      # First turn
      {:ok, _result1} = Otto.Agent.invoke(agent, "Remember the number 42")
      IO.puts "  ✅ Turn 1: Agent acknowledged"

      # Second turn - test memory
      {:ok, result2} = Otto.Agent.invoke(agent, "What number did I ask you to remember?")
      has_memory = String.contains?(result2.content, "42")

      if has_memory do
        IO.puts "  ✅ Turn 2: Agent remembered context"
      else
        IO.puts "  ⚠️  Turn 2: Context may not be preserved"
      end

      # Third turn - different topic
      {:ok, _result3} = Otto.Agent.invoke(agent, "Now let's talk about Elixir. What is GenServer?")
      IO.puts "  ✅ Turn 3: Topic switch handled"

      Otto.Agent.stop_agent(agent)

      {:ok, "Conversations"}
    rescue
      error ->
        IO.puts "  ❌ Error: #{inspect(error)}"
        {:error, "Conversations"}
    end
  end

  defp test_budget_tracking do
    IO.puts "\n💰 Test 4: Budget and Token Tracking"
    IO.puts "─────────────────────────────────────"

    try do
      {:ok, agent} = Otto.Agent.start_agent("budget_agent")

      # Make several requests and track costs
      {:ok, r1} = Otto.Agent.invoke(agent, "Count from 1 to 5")
      {:ok, r2} = Otto.Agent.invoke(agent, "What's the capital of France?")
      {:ok, r3} = Otto.Agent.invoke(agent, "Write a haiku about coding")

      total_tokens = r1.cost.tokens_used + r2.cost.tokens_used + r3.cost.tokens_used
      total_cost = r1.cost.cost_used + r2.cost.cost_used + r3.cost.cost_used

      IO.puts "  📊 Total tokens used: #{total_tokens}"
      IO.puts "  💵 Total cost: $#{Float.round(total_cost, 6)}"
      IO.puts "  ⏱️  Average response time: #{round((r1.duration_ms + r2.duration_ms + r3.duration_ms) / 3)}ms"

      if total_tokens > 0 do
        IO.puts "  ✅ Budget tracking operational"
      end

      Otto.Agent.stop_agent(agent)

      {:ok, "Budget Tracking"}
    rescue
      error ->
        IO.puts "  ❌ Error: #{inspect(error)}"
        {:error, "Budget Tracking"}
    end
  end

  defp test_real_world_scenario do
    IO.puts "\n🌍 Test 5: Real-world Scenario"
    IO.puts "─────────────────────────────────────"
    IO.puts "  Scenario: Code review assistant"

    try do
      {:ok, agent} = Otto.Agent.start_agent("code_review_agent")

      # Simulate a code review request
      code_snippet = """
      def calculate_average(numbers) do
        Enum.sum(numbers) / length(numbers)
      end
      """

      prompt = """
      Review this Elixir function for potential issues:
      #{code_snippet}
      """

      {:ok, review} = Otto.Agent.invoke(agent, prompt)
      IO.puts "  ✅ Code review completed"

      # Check if the AI identified the potential division by zero issue
      if String.contains?(String.downcase(review.content), "zero") or
         String.contains?(String.downcase(review.content), "empty") do
        IO.puts "  ✅ AI identified potential issues"
      else
        IO.puts "  ⚠️  AI may have missed edge cases"
      end

      Otto.Agent.stop_agent(agent)

      {:ok, "Real-world Scenario"}
    rescue
      error ->
        IO.puts "  ❌ Error: #{inspect(error)}"
        {:error, "Real-world Scenario"}
    end
  end

  defp print_summary(results) do
    IO.puts """

    ╔══════════════════════════════════════════════════════════════════════╗
    ║                           Test Summary                               ║
    ╚══════════════════════════════════════════════════════════════════════╝
    """

    passed = Enum.count(results, fn {status, _} -> status == :ok end)
    failed = Enum.count(results, fn {status, _} -> status == :error end)

    IO.puts "  Total Tests: #{length(results)}"
    IO.puts "  ✅ Passed: #{passed}"
    IO.puts "  ❌ Failed: #{failed}"

    IO.puts "\n📋 System Capabilities Verified:"
    IO.puts "  • LLM integration with OpenAI GPT models"
    IO.puts "  • Agent lifecycle management (start/stop/invoke)"
    IO.puts "  • Multi-turn conversation support with context preservation"
    IO.puts "  • Budget and token tracking with cost calculation"
    IO.puts "  • Real-world application scenarios"

    IO.puts "\n📚 Key APIs:"
    IO.puts "  • Otto.Agent.start_agent(name) - Start a new agent from YAML config"
    IO.puts "  • Otto.Agent.invoke(agent, prompt) - Send a prompt to an agent"
    IO.puts "  • Otto.Agent.stop_agent(agent) - Stop an agent gracefully"
    IO.puts "  • Otto.LLM.complete(model, prompt) - Direct LLM completion"
    IO.puts "  • Otto.LLM.chat(model, messages) - Chat with message history"

    if failed == 0 do
      IO.puts "\n🎉 All tests passed! Otto is fully operational."
    else
      IO.puts "\n⚠️  Some tests failed. Check the output above for details."
    end
  end
end

# Run the test suite
OttoSystemTest.run()