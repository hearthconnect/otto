defmodule Otto.Agent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Agent-specific registry (separate from Otto.Registry in Manager)
      {Registry, keys: :unique, name: Otto.Agent.Registry},

      # Dynamic supervisor for agent instances
      {DynamicSupervisor, name: Otto.Agent.DynamicSupervisor, strategy: :one_for_one}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Otto.Agent.Application.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
