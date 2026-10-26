defmodule JevDSL.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/boxxxie/jev_dsl"

  def project do
    [
      app: :jev_dsl,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description:
        "Compile-time contract DSL, two-tier content-addressed cache, and execution runner for TypeSafe Jev (SystemOneSDK).",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp deps do
    [
      {:system_one_sdk, "~> 0.6.0"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md usage-rules.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "usage-rules.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Contract DSL": [
          JevDSL,
          JevDSL.Contract,
          JevDSL.Question,
          JevDSL.CUE
        ],
        "Caching & Execution": [
          JevDSL.Runner,
          JevDSL.Cache,
          JevDSL.Cache.ETS
        ]
      ]
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ]
    ]
  end
end
