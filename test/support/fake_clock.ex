defmodule Maat.FakeClock do
  @moduledoc "Controllable clock for tests. The engine reads time only through the clock module."

  use GenServer

  def start_link(_opts \\ []),
    do:
      GenServer.start_link(__MODULE__, Elixir.System.system_time(:millisecond), name: __MODULE__)

  def init(now), do: {:ok, now}

  def now_ms, do: GenServer.call(__MODULE__, :now)
  def set(ms), do: GenServer.call(__MODULE__, {:set, ms})
  def advance(ms), do: GenServer.call(__MODULE__, {:advance, ms})

  def handle_call(:now, _from, now), do: {:reply, now, now}
  def handle_call({:set, ms}, _from, _now), do: {:reply, :ok, ms}
  def handle_call({:advance, ms}, _from, now), do: {:reply, now + ms, now + ms}
end
