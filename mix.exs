defmodule Postgrext.MixProject do
  use Mix.Project

  def project do
    [
      app: :postgrext,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Postgrext.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:postgrex, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:req, "~> 0.5", only: :test}
    ]
  end
end
