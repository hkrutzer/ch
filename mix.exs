defmodule Ch.MixProject do
  use Mix.Project

  @source_url "https://github.com/plausible/ch"
  @version "0.3.0"

  def project do
    [
      app: :ch,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Ch",
      description: "HTTP ClickHouse driver for Elixir",
      docs: [
        source_url: @source_url,
        source_ref: "v#{@version}",
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
      ],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url}
      ],
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:db_connection, "~> 2.0"},
      {:decimal, "~> 2.0"},
      {:ecto, "~> 3.5", optional: true},
      {:benchee, "~> 1.0", only: :bench},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :docs},
      {:tz, "~> 0.26.0", only: :test}
    ]
  end
end
