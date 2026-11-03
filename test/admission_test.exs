defmodule Maat.AdmissionTest do
  use ExUnit.Case, async: true

  import Maat.TestGenerators, only: [manifests: 0]

  alias Maat.Graph.Admission
  alias Maat.Graph.Registry

  defp graph(nodes, edges, entry, comp \\ %{}) do
    %{
      "api_version" => "maat/v1alpha1",
      "nodes" => nodes,
      "edges" => edges,
      "entry" => entry,
      "compensation" => comp
    }
  end

  defp emit_node, do: %{"kind" => "emit", "config" => %{"event" => %{"type" => "ping"}}}
  defp resize_node(extra \\ %{}), do: Map.merge(%{"kind" => "resize"}, extra)

  test "valid graph passes" do
    assert :ok =
             Admission.validate(graph(%{"n1" => emit_node()}, [], "n1"), manifests: manifests())
  end

  test "3001 on schema violation" do
    g = graph(%{"n1" => emit_node()}, [], "n1")
    g = put_in(g, ["api_version"], "wrong/v1")
    assert {:error, "3001", _} = Admission.validate(g, manifests: manifests())
  end

  test "3001 on empty graph" do
    g = graph(%{}, [], "n1")
    assert {:error, "3001", _} = Admission.validate(g, manifests: manifests())
  end

  test "3002 on unknown node kind" do
    g = graph(%{"n1" => %{"kind" => "teleport"}}, [], "n1")
    assert {:error, "3002", _} = Admission.validate(g, manifests: manifests())
  end

  test "3003 on side-effecting node without compensation" do
    g = graph(%{"n1" => resize_node()}, [], "n1")
    assert {:error, "3003", _} = Admission.validate(g, manifests: manifests())
  end

  test "side-effecting node passes with no_compensate or compensation" do
    g1 = graph(%{"n1" => resize_node(%{"no_compensate" => true})}, [], "n1")
    assert :ok = Admission.validate(g1, manifests: manifests())

    g2 = graph(%{"n1" => resize_node(), "c1" => emit_node()}, [], "n1", %{"n1" => "c1"})
    assert :ok = Admission.validate(g2, manifests: manifests())
  end

  test "3004 on unreachable node" do
    g =
      graph(%{"n1" => emit_node(), "n2" => emit_node()}, [%{"from" => "n1", "to" => "n1"}], "n1")

    assert {:error, "3004", _} = Admission.validate(g, manifests: manifests())
  end

  test "3005 on compensation of compensation" do
    g =
      graph(%{"n1" => resize_node(), "c1" => emit_node()}, [], "n1", %{"n1" => "c1", "c1" => "n1"})

    assert {:error, "3005", _} = Admission.validate(g, manifests: manifests())
  end

  test "registry is content-addressed and versioned" do
    g = graph(%{"n1" => emit_node()}, [], "n1")
    {:ok, id1, v1} = Registry.put_spec(g, manifests: manifests())
    {:ok, id2, v2} = Registry.put_spec(g, manifests: manifests())
    assert id1 == id2 and v1 == v2

    g2 =
      graph(%{"n1" => emit_node(), "n2" => emit_node()}, [%{"from" => "n1", "to" => "n2"}], "n1")

    {:ok, id3, v3} = Registry.put_spec(g2, manifests: manifests())
    assert id3 != id1 and v3 == 1

    assert ^g = Registry.get(id1, v1)
  end
end
