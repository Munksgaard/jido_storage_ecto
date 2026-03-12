defmodule JidoStorageEcto.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_storage_ecto"
  @description "PostgreSQL storage adapter for Jido agent checkpoints and thread journals"

  def project do
    [
      app: :jido_storage_ecto,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Docs
      name: "Jido Storage Ecto",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jido, "~> 2.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},

      # Dev/Test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      files: ["lib", ".formatter.exs", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["AgentJido", "Philip Munksgaard"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Jido" => "https://github.com/agentjido/jido"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "test"]
    ]
  end
end
