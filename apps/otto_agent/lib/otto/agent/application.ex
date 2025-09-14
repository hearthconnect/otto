defmodule Otto.Agent.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Core infrastructure
      {Otto.ToolBus, []},

      # Registry for agent process lookup
      {Registry, keys: :unique, name: Otto.Agent.Registry},

      # Dynamic supervisor for agent instances
      {DynamicSupervisor, name: Otto.Agent.DynamicSupervisor, strategy: :one_for_one},

      # Context and artifact storage
      Otto.ContextStore,
      Otto.Checkpointer,
      Otto.CostTracker
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Otto.Agent.Application]
    Supervisor.start_link(children, opts)
  end
end
