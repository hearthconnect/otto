defmodule Otto.Agent.MixProject do
  use Mix.Project

  def project do
    [
      app: :otto_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Otto.Agent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:yaml_elixir, "~> 2.11"},
      {:nimble_options, "~> 1.1"},
      {:httpoison, "~> 2.2"},
      {:jason, "~> 1.4"},
      {:otto_manager, in_umbrella: true},
      {:otto_llm, in_umbrella: true}
    ]
  end
end
