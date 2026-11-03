defmodule Maat.TestGenerators do
  @moduledoc "StreamData generators for graphs and event scripts."

  import StreamData

  @start_ms 1_000_000

  def start_ms, do: @start_ms

  def iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  def manifests do
    %{
      "resize" => %{
        "transport" => "http",
        "input" => %{"type" => "object"},
        "output" => %{"type" => "object"},
        "timeout_s" => 5,
        "side_effects" => true
      }
    }
  end

  def graph_gen do
    bind({integer(1..3), boolean()}, fn {n, with_comp} ->
      bind(list_of(node_def_gen(), min_length: n, max_length: n), fn defs ->
        ids = Enum.map(1..n, &"n#{&1}")
        pairs = Enum.zip(ids, defs)
        nodes = Map.new(pairs)

        {nodes, comp} =
          if with_comp do
            case Enum.find(pairs, fn {_id, d} -> d["kind"] == "resize" end) do
              {rid, _} ->
                {Map.put(nodes, "c1", %{
                   "kind" => "emit",
                   "config" => %{"event" => %{"type" => "compensated"}}
                 }), %{rid => "c1"}}

              nil ->
                {nodes, %{}}
            end
          else
            {nodes, %{}}
          end

        edges =
          if n > 1,
            do: Enum.map(1..(n - 1), fn i -> %{"from" => "n#{i}", "to" => "n#{i + 1}"} end),
            else: []

        constant(%{
          "api_version" => "maat/v1alpha1",
          "nodes" => nodes,
          "edges" => edges,
          "entry" => "n1",
          "compensation" => comp
        })
      end)
    end)
  end

  defp node_def_gen do
    one_of([
      resize_def(),
      constant(%{"kind" => "emit", "config" => %{"event" => %{"type" => "ping"}}}),
      sleep_def(),
      wait_def(),
      constant(%{"kind" => "fail"})
    ])
  end

  defp resize_def do
    map({integer(1..3), integer(0..1000)}, fn {max, backoff} ->
      %{
        "kind" => "resize",
        "no_compensate" => true,
        "retry" => %{"max_attempts" => max, "backoff_ms" => backoff}
      }
    end)
  end

  defp sleep_def do
    map(integer(1..5000), fn off ->
      %{"kind" => "sleep_until", "config" => %{"at" => iso(@start_ms + off)}}
    end)
  end

  defp wait_def, do: constant(%{"kind" => "wait_for_signal", "config" => %{"signal" => "go"}})

  def script_gen(graph) do
    node_ids = Map.keys(graph["nodes"])

    signals =
      graph["nodes"]
      |> Enum.filter(fn {_id, d} -> d["kind"] == "wait_for_signal" end)
      |> Enum.map(fn {_id, d} -> d["config"]["signal"] end)

    list_of(step_gen(node_ids, signals), max_length: 12)
  end

  defp step_gen(node_ids, signals) do
    base = [
      map({member_of(node_ids), outcome_gen()}, fn {id, o} -> {:respond, id, o} end),
      map(integer(1..5000), &{:advance, &1}),
      constant({:kill}),
      constant({:noop})
    ]

    base =
      if signals == [], do: base, else: base ++ [map(member_of(signals), &{:signal, &1, %{}})]

    one_of(base)
  end

  defp outcome_gen do
    frequency([{5, constant(:ok)}, {1, constant(:unknown)}, {1, constant(:deterministic_error)}])
  end

  def json_term, do: json_term(3)

  defp json_term(0), do: one_of([string(:alphanumeric), integer(), boolean(), constant(nil)])

  defp json_term(d) do
    one_of([
      json_term(0),
      list_of(json_term(d - 1), max_length: 4),
      map_of(string(:alphanumeric), json_term(d - 1), max_length: 4)
    ])
  end
end
