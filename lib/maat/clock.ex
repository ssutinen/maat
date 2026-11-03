defmodule Maat.Clock do
  @moduledoc """
  Clock behaviour. The engine never reads the wall clock directly; it goes
  through this module so tests can substitute a fake clock. `Process.send_after`
  is a wake-up hint only — absolute deadlines live in storage, never in timers.
  """

  @callback now_ms() :: integer()

  def now_ms(mod), do: mod.now_ms()

  defmodule System do
    @behaviour Maat.Clock
    @impl true
    def now_ms, do: Elixir.System.system_time(:millisecond)
  end
end
