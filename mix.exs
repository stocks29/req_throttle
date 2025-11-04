defmodule ReqThrottle.MixProject do
  use Mix.Project

  def project do
    [
      app: :req_throttle,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      source_url: "https://github.com/stocks29/req_throttle",
      homepage_url: "https://github.com/stocks29/req_throttle",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A Req plugin for rate limiting and throttling HTTP requests to external services. " <>
      "Provides a flexible, pluggable rate limiting solution with support for blocking and error modes."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/stocks29/req_throttle"
      }
    ]
  end
end
