defmodule Maat.Property.DeterminismTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Maat.TestGenerators

  alias Maat.Canonical

  @moduletag :property

  property "same (graph, state, event) gives byte-identical decisions" do
    check all(graph <- graph_gen(), max_runs: 30) do
      check all({script, seed} <- {script_gen(graph), integer()}, max_runs: 30) do
        s1 = Maat.TestHarness.pure_run(graph, "g", 1, script, seed)
        s2 = Maat.TestHarness.pure_run(graph, "g", 1, script, seed)
        assert Canonical.encode!(s1) == Canonical.encode!(s2)
      end
    end
  end
end
