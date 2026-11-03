defmodule Maat.Engine.Sweeper do
  @moduledoc """
  Timer sweeper (SPECIFICATION.md section 3). Persists nothing itself — it
  scans the event trail for `:timer_due` entries and wakes the owning
  instance. `Process.send_after` is only a wake-up hint; the persisted absolute
  deadline is the truth. In tests, call `tick/0` manually with a fake clock.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 10_000)

  @impl true
  def init(opts) do
    interval =
      Keyword.get(opts, :interval_ms, Application.get_env(:maat, :sweeper_interval_ms, 1_000))

    Process.send_after(self(), :tick, interval)

    {:ok,
     %{
       storage: Keyword.get(opts, :storage, Maat.Storage.Memory),
       clock: Keyword.get(opts, :clock, Application.get_env(:maat, :clock, Maat.Clock.System)),
       interval_ms: interval,
       since: 0
     }}
  end

  @impl true
  def handle_info(:tick, st), do: {:noreply, do_tick(st)}

  @impl true
  def handle_call(:tick, _from, st), do: {:reply, :ok, do_tick(st)}

  defp do_tick(st) do
    now = st.clock.now_ms()
    entries = st.storage.scan("instance/", st.since)

    Enum.each(entries, fn
      %{kind: "timer_due", key: key, id: id} ->
        instance_id = String.replace_prefix(key, "instance/", "")

        case Registry.lookup(Maat.InstanceRegistry, instance_id) do
          [{pid, _}] ->
            try do
              GenServer.call(pid, {:event, {:timer, id, now}}, 5_000)
            rescue
              _ -> :ok
            catch
              :exit, _ -> :ok
            end

          [] ->
            :ok
        end

      _ ->
        :ok
    end)

    # Timer entries are never consumed from `since`, so a timer that was not
    # yet due is re-examined on the next tick.
    since =
      entries
      |> Enum.reject(&(&1.kind == "timer" or (&1[:event] && &1.event["kind"] == "timer")))
      |> Enum.map(& &1.seq)
      |> Enum.max(fn -> st.since end)

    %{st | since: since}
  end
end
