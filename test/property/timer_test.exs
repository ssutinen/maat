defmodule Maat.Property.TimerTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Maat.TestGenerators, only: [iso: 1, start_ms: 0]

  @moduletag :property

  property "absolute deadlines fire correctly across simulated restarts and clock jitter" do
    check all({offset, jitter} <- {integer(1..10_000), list_of(integer(1..500), max_length: 20)}) do
      at_ms = start_ms() + offset

      graph = %{
        "api_version" => "maat/v1alpha1",
        "nodes" => %{"n1" => %{"kind" => "sleep_until", "config" => %{"at" => iso(at_ms)}}},
        "edges" => [],
        "entry" => "n1",
        "compensation" => %{}
      }

      iid = "timer#{System.unique_integer([:positive])}"
      {:ok, pid, _gid, _v} = Maat.start_instance(graph, iid, manifests: %{})
      Maat.FakeClock.set(start_ms())

      # crash the instance while it is blocked on the timer
      Process.exit(pid, :kill)

      Enum.find_value(1..200, fn _ ->
        Process.sleep(5)

        case Registry.lookup(Maat.InstanceRegistry, iid) do
          [{p, _}] -> if Process.alive?(p), do: p
          [] -> nil
        end
      end)

      # jitter the clock forward in irregular steps, ticking the sweeper
      Enum.each(jitter, fn step ->
        Maat.FakeClock.advance(step)
        Maat.Engine.Sweeper.tick()
      end)

      Maat.FakeClock.advance(10_000)
      Maat.Engine.Sweeper.tick()

      assert {:ok, st, _ver} = Maat.get_instance(iid)
      assert st["status"] == "completed"

      {:ok, fired, _} = DateTime.from_iso8601(st["nodes"]["n1"]["output"]["fired_at"])
      assert DateTime.to_unix(fired, :millisecond) >= at_ms
    end
  end
end
