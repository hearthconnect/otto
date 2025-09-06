defmodule Otto.LLMTest do
  use ExUnit.Case
  doctest Otto.LLM

  test "greets the world" do
    assert Otto.LLM.hello() == :world
  end
end
