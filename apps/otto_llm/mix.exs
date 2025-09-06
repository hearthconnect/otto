defmodule Otto.LLM.MixProject do
  use Mix.Project

  def project do
    [
      app: :otto_llm,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.unit": :test,
        "test.integration": :test,
        "test.all": :test,
        "test.quick": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Otto.LLM.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Aliases for iterative development
  defp aliases do
    [
      "test.unit": ["test"],
      "test.integration": ["INTEGRATION_TESTS=1 mix test --include integration"],
      "test.all": ["test.unit", "test.integration"],
      "test.watch": ["test.auto"],
      "test.quick": ["test --max-failures 1 --trace"]
    ]
  end
end
