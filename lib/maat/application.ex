defmodule Maat.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    storage_mod = Application.get_env(:maat, :storage, Maat.Storage.Memory)
    clock = Application.get_env(:maat, :clock, Maat.Clock.System)

    children = [
      {Registry, keys: :unique, name: Maat.InstanceRegistry},
      {Maat.Graph.Registry, []},
      {storage_mod, [clock: clock]},
      Maat.Engine.Supervisor,
      {Maat.Engine.Sweeper,
       [
         storage: storage_mod,
         clock: clock,
         interval_ms: Application.get_env(:maat, :sweeper_interval_ms, 1_000)
       ]}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Maat.Supervisor,
      max_restarts: Application.get_env(:maat, :max_restarts, 3),
      max_seconds: Application.get_env(:maat, :max_seconds, 5)
    )
  end
end
