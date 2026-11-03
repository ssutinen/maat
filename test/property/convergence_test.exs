defmodule Maat.Property.ConvergenceTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Maat.TestGenerators

  alias Maat.Canonical

  @moduletag :property
  @moduletag timeout: 300_000

  property "crash-injected runs converge to the same terminal state as crash-free runs" do
    check all(graph <- graph_gen(), max_runs: 20) do
      check all({script, seed} <- {script_gen(graph), integer()}, max_runs: 20) do
        manifests = manifests()
        {:ok, graph_id, version} = Maat.Graph.Registry.put_spec(graph, manifests: manifests)

        reference = Maat.TestHarness.pure_run(graph, graph_id, version, script, seed)

        {live, versions} =
          Maat.TestHarness.live_run(graph, graph_id, version, script, seed, manifests)

        assert live["status"] in ["completed", "failed"]
        assert reference["status"] == live["status"]
        assert Canonical.encode!(live) == Canonical.encode!(reference)

        # storage version is monotonic non-decreasing across crashes
        assert versions == Enum.sort(versions)
      end
    end
  end
end
