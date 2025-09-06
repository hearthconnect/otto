defmodule Otto.AgentTest do
  use ExUnit.Case
  doctest Otto.Agent

  test "greets the world" do
    assert Otto.Agent.hello() == :world
  end
end
