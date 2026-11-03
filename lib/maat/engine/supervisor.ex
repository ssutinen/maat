defmodule Maat.Engine.Supervisor do
  @moduledoc "DynamicSupervisor holding one instance process per active key."

  use DynamicSupervisor

  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def start_instance(opts),
    do: DynamicSupervisor.start_child(__MODULE__, {Maat.Engine.Instance, opts})

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: Application.get_env(:maat, :max_restarts, 3),
      max_seconds: Application.get_env(:maat, :max_seconds, 5)
    )
  end
end
