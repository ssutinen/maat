defmodule Maat.InterpreterTest do
  use ExUnit.Case, async: true

  alias Maat.Engine.Interpreter

  @now 1_000_000

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

  defp resize_node(extra \\ %{}),
    do: Map.merge(%{"kind" => "resize", "no_compensate" => true, "timeout_s" => 5}, extra)

  test "linear graph: start invokes entry, results drive to completion" do
    g =
      graph(
        %{"n1" => resize_node(), "n2" => emit_node()},
        [%{"from" => "n1", "to" => "n2"}],
        "n1"
      )

    st = Interpreter.init(g, "g", 1)

    {st, [invoke]} = Interpreter.decide(g, st, {:start, @now})
    assert {:invoke, "n1", attempt_id, idem_key, %{}, deadline} = invoke
    assert deadline == @now + 5_000
    assert st["nodes"]["n1"]["status"] == "running"
    assert st["nodes"]["n1"]["idempotency_key"] == idem_key

    {st, actions} =
      Interpreter.decide(g, st, {:result, attempt_id, :ok, %{"ok" => true}, nil, @now + 1})

    assert st["nodes"]["n1"]["status"] == "completed"
    # n2 is emit: completes immediately, instance completes
    assert st["status"] == "completed"
    assert {:complete, _} = List.last(actions)
  end

  test "transport-unknown retries with the same idempotency key via a persisted timer" do
    g =
      graph(
        %{"n1" => resize_node(%{"retry" => %{"max_attempts" => 2, "backoff_ms" => 100}})},
        [],
        "n1"
      )

    st = Interpreter.init(g, "g", 1)
    {st, [{:invoke, "n1", a1, key, _, _}]} = Interpreter.decide(g, st, {:start, @now})

    {st, [{:timer, timer_id, at}]} =
      Interpreter.decide(g, st, {:result, a1, :unknown, nil, "1002", @now + 1})

    assert at == @now + 1 + 100
    assert st["nodes"]["n1"]["status"] == "blocked"

    {st, [{:invoke, "n1", a2, key2, _, _}]} = Interpreter.decide(g, st, {:timer, timer_id, at})
    assert a2 != a1
    assert key2 == key
    assert st["nodes"]["n1"]["attempts"] == 2
  end

  test "deterministic error with exhausted budget fails without compensation" do
    g = graph(%{"n1" => resize_node(%{"retry" => %{"max_attempts" => 1}})}, [], "n1")
    st = Interpreter.init(g, "g", 1)
    {st, [{:invoke, "n1", a1, _, _, _}]} = Interpreter.decide(g, st, {:start, @now})

    {st, [{:fail, "2001", _}]} =
      Interpreter.decide(g, st, {:result, a1, :deterministic_error, nil, "2001", @now + 1})

    assert st["status"] == "failed"
  end

  test "compensation runs LIFO and ends failed with a summary" do
    g =
      graph(
        %{
          "n1" => resize_node(%{"no_compensate" => false, "retry" => %{"max_attempts" => 1}}),
          "c1" => emit_node()
        },
        [],
        "n1",
        %{"n1" => "c1"}
      )

    st = Interpreter.init(g, "g", 1)
    {st, [{:invoke, "n1", a1, _, _, _}]} = Interpreter.decide(g, st, {:start, @now})

    {st, [{:invoke, "c1", ca, _, _, _}]} =
      Interpreter.decide(g, st, {:result, a1, :deterministic_error, nil, "2001", @now + 1})

    assert st["status"] == "compensating"
    assert st["compensation"]["pending"] == []

    {st, [{:fail, "2001", _}]} = Interpreter.decide(g, st, {:result, ca, :ok, %{}, nil, @now + 2})
    assert st["status"] == "failed"
    assert st["compensation"]["done"] == %{"c1" => "ok"}
  end

  test "wait_for_signal blocks and completes on matching signal" do
    g =
      graph(%{"n1" => %{"kind" => "wait_for_signal", "config" => %{"signal" => "go"}}}, [], "n1")

    st = Interpreter.init(g, "g", 1)
    {st, [{:noop}]} = Interpreter.decide(g, st, {:start, @now})
    assert st["nodes"]["n1"]["status"] == "blocked"

    {st, [{:noop}]} = Interpreter.decide(g, st, {:signal, "other", %{}, @now + 1})
    assert st["nodes"]["n1"]["status"] == "blocked"

    {st, [{:complete, _}]} = Interpreter.decide(g, st, {:signal, "go", %{"x" => 1}, @now + 2})
    assert st["status"] == "completed"
    assert st["nodes"]["n1"]["output"] == %{"x" => 1}
  end

  test "sleep_until blocks on a persisted absolute deadline and wakes" do
    at = Maat.TestGenerators.iso(@now + 5_000)
    g = graph(%{"n1" => %{"kind" => "sleep_until", "config" => %{"at" => at}}}, [], "n1")
    st = Interpreter.init(g, "g", 1)
    {st, [{:timer, "n1", at_ms}]} = Interpreter.decide(g, st, {:start, @now})
    assert at_ms == @now + 5_000

    {st, [{:complete, _}]} = Interpreter.decide(g, st, {:timer, "n1", at_ms})
    assert st["status"] == "completed"
    assert st["nodes"]["n1"]["output"]["fired_at"] != nil
  end

  test "resume re-derives pending invokes and timers without changing state" do
    at = Maat.TestGenerators.iso(@now + 5_000)

    g =
      graph(
        %{"n1" => resize_node(), "n2" => %{"kind" => "sleep_until", "config" => %{"at" => at}}},
        [%{"from" => "n1", "to" => "n2"}],
        "n1"
      )

    st = Interpreter.init(g, "g", 1)
    {st, [{:invoke, "n1", a1, key, _, _}]} = Interpreter.decide(g, st, {:start, @now})
    {st, actions} = Interpreter.decide(g, st, {:resume, @now + 10})

    assert {:invoke, "n1", ^a1, ^key, _, _} =
             Enum.find(actions, &match?({:invoke, _, ^a1, _, _, _}, &1))

    assert Maat.Canonical.encode!(st) ==
             Maat.Canonical.encode!(Interpreter.decide(g, st, {:resume, @now + 10}) |> elem(0))
  end
end
