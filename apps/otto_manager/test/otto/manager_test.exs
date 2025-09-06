defmodule Otto.ManagerTest do
  use ExUnit.Case
  doctest Otto.Manager

  test "greets the world" do
    assert Otto.Manager.hello() == :world
  end
end
