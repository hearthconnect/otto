defmodule Otto.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      {:tidewave, "~> 0.4", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:usage_rules, "~> 0.1", only: [:dev]}
    ]
  end

  defp aliases do
    [
      "usage_rules.update": [
        "usage_rules.sync AGENTS.md --all --inline usage_rules:all --link-to-folder deps"
      ]
    ]
  end
end
