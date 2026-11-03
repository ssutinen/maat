defmodule Maat.MixProject do
  use Mix.Project

  def project do
    [
      app: :maat,
      version: "0.1.0",
      # SPECIFICATION.md: Elixir >= 1.20 on OTP 27+ (verified: 1.20.0 released
      # 2026-06-03, requires OTP 27+, compatible with OTP 29).
      elixir: ">= 1.20.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: [licenses: ["MIT"], files: ~w(lib schemas mix.exs)],
      docs: [main: "Maat", extras: ["SPECIFICATION.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Maat.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Per SPECIFICATION.md section 12. All permissive (MIT/Apache-2.0).
  # Ra is deliberately absent: future phase only, separate package.
  defp deps do
    [
      {:jason, "~> 1.4.0"},
      {:nimble_options, "~> 1.1.0"},
      {:ex_json_schema, "~> 0.11.0"},
      {:bandit, "~> 1.14.0"},
      {:plug, "~> 1.20.0"},
      {:req, "~> 0.7.0"},
      {:ecto, "~> 3.14.0"},
      {:ecto_sqlite3, "~> 0.26.0"},
      {:stream_data, "~> 1.4.0", only: :test}
    ]
  end
end
