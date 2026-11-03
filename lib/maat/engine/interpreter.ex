defmodule Maat.Engine.Interpreter do
  @moduledoc """
  The pure decision function: `(graph, state, event) -> {state', actions}`.
  No IO. No clock reads — `now` arrives inside every event.

  Deterministic by construction: attempt ids, idempotency keys, retry delays,
  and jitter are derived only from `(graph, state, event)`, so equal inputs
  yield byte-identical outputs (property-tested).

  Events: `{:start, now}` `{:resume, now}` `{:result, attempt_id, outcome,
  output, error_code, now}` `{:signal, name, payload, now}` `{:timer, timer_id,
  now}` `{:child_result, child_id, status, now}`.

  Actions: `{:invoke, node, attempt_id, idempotency_key, input, deadline_ms}`
  `{:timer, timer_id, at_ms}` `{:emit, map}` `{:enqueue, node, child_id,
  graph_id, input}` `{:complete, now}` `{:fail, code, now}` `{:noop}`.
  """

  alias Maat.Canonical

  @effect_kinds ~w(http enqueue sleep_until wait_for_signal emit fail)

  @effect_side_effects %{
    "http" => true,
    "enqueue" => true,
    "sleep_until" => false,
    "wait_for_signal" => false,
    "emit" => false,
    "fail" => false
  }

  def effect_kind?(kind), do: kind in @effect_kinds
  def effect_side_effects(kind), do: Map.fetch!(@effect_side_effects, kind)

  def init(graph, graph_id, graph_version, vars \\ %{}) do
    nodes =
      Map.new(graph["nodes"], fn {id, _def} ->
        {id,
         %{
           "status" => "pending",
           "output" => nil,
           "attempt_id" => nil,
           "idempotency_key" => nil,
           "attempts" => 0,
           "blocked" => nil
         }}
      end)

    %{
      "status" => "admitted",
      "graph_id" => graph_id,
      "graph_version" => graph_version,
      "nodes" => nodes,
      "vars" => vars,
      "blocked_on" => nil,
      "completed_order" => [],
      "compensation" => nil
    }
  end

  def decide(graph, state, {:start, now}),
    do: schedule(graph, %{state | "status" => "running"}, now)

  def decide(graph, state, {:resume, now}) do
    state = if state["status"] == "admitted", do: %{state | "status" => "running"}, else: state
    resume(graph, state, now)
  end

  def decide(graph, state, {:result, attempt_id, outcome, output, error_code, now}) do
    if state["status"] == "compensating" do
      handle_comp_result(graph, state, attempt_id, outcome, output, error_code, now)
    else
      handle_result(graph, state, attempt_id, outcome, output, error_code, now)
    end
  end

  def decide(graph, state, {:signal, name, payload, now}),
    do: handle_signal(graph, state, name, payload, now)

  def decide(graph, state, {:timer, timer_id, now}), do: handle_timer(graph, state, timer_id, now)

  def decide(graph, state, {:child_result, child_id, child_status, now}),
    do: handle_child(graph, state, child_id, child_status, now)

  # --- traversal -----------------------------------------------------------

  defp schedule(graph, state, now), do: schedule_loop(graph, state, now, [])

  # Iterate to a fixpoint: completing one node can make dependents ready.
  defp schedule_loop(graph, state, now, acc) do
    case ready_nodes(graph, state) do
      [] ->
        check_terminal(graph, touch(state), now, acc)

      ready ->
        {state, actions} =
          Enum.reduce(ready, {state, []}, fn id, {st, a} ->
            {st, action} = start_node(graph, st, id, now)
            {st, a ++ [action]}
          end)

        schedule_loop(graph, state, now, acc ++ actions)
    end
  end

  defp ready_nodes(graph, state) do
    Enum.filter(Map.keys(graph["nodes"]), fn id ->
      state["nodes"][id]["status"] == "pending" and ready?(graph, state, id)
    end)
  end

  defp ready?(graph, state, id) do
    if id == graph["entry"] do
      true
    else
      graph["edges"]
      |> Enum.filter(&(&1["to"] == id))
      |> Enum.any?(fn e ->
        from = state["nodes"][e["from"]]
        from != nil and from["status"] == "completed" and when_matches?(e["when"], from["output"])
      end)
    end
  end

  defp when_matches?(nil, _output), do: true

  defp when_matches?(pred, output) when is_map(pred) do
    Enum.all?(pred, fn {k, v} -> get_in(output || %{}, String.split(k, ".")) == v end)
  end

  defp when_matches?(_, _), do: false

  defp start_node(graph, state, id, now) do
    node_def = graph["nodes"][id]
    kind = node_def["kind"]
    config = node_def["config"] || %{}
    node = state["nodes"][id]
    input = Map.get(state["vars"], "input:" <> id, config["input"] || %{})

    case kind do
      "emit" ->
        node = %{node | "status" => "completed", "output" => %{}}
        {touch(put_node(state, id, node)), {:emit, config["event"] || %{}}}

      "fail" ->
        # failure_path returns {state, [action]}; start_node must yield a single action.
        {st, [action]} =
          failure_path(
            graph,
            touch(put_node(state, id, %{node | "status" => "failed"})),
            id,
            "2001",
            now
          )

        {st, action}

      "sleep_until" ->
        at_ms = parse_rfc3339!(config["at"])
        blocked = %{"reason" => "timer", "timer" => id, "at" => at_ms, "since" => iso(now)}
        node = %{node | "status" => "blocked", "blocked" => blocked}
        {touch(put_node(state, id, node)), {:timer, id, at_ms}}

      "wait_for_signal" ->
        blocked = %{"reason" => "signal", "signal" => config["signal"], "since" => iso(now)}
        node = %{node | "status" => "blocked", "blocked" => blocked}
        {touch(put_node(state, id, node)), {:noop}}

      "enqueue" ->
        child_id = "c" <> Canonical.hash(%{"g" => state["graph_id"], "n" => id})

        if config["block_on_child"] == false do
          node = %{node | "status" => "completed", "output" => %{"child_id" => child_id}}

          {touch(put_node(state, id, node)),
           {:enqueue, id, child_id, config["graph"], config["input"] || %{}}}
        else
          blocked = %{"reason" => "child", "child" => child_id, "since" => iso(now)}
          node = %{node | "status" => "blocked", "blocked" => blocked}

          {touch(put_node(state, id, node)),
           {:enqueue, id, child_id, config["graph"], config["input"] || %{}}}
        end

      _ ->
        invoke_node(graph, state, id, input, now)
    end
  end

  defp invoke_node(graph, state, id, input, now) do
    node_def = graph["nodes"][id]
    node = state["nodes"][id]
    {attempt_id, idem_key} = next_attempt(state, id, input)
    timeout_s = node_def["timeout_s"] || 300

    node = %{
      node
      | "status" => "running",
        "attempt_id" => attempt_id,
        "idempotency_key" => idem_key,
        "attempts" => node["attempts"] + 1,
        "blocked" => nil
    }

    {touch(put_node(state, id, node)),
     {:invoke, id, attempt_id, idem_key, input, now + timeout_s * 1000}}
  end

  defp next_attempt(state, id, input) do
    n = state["nodes"][id]["attempts"] + 1

    attempt_id =
      "a" <>
        Canonical.hash(%{
          "g" => state["graph_id"],
          "v" => state["graph_version"],
          "n" => id,
          "k" => n,
          "i" => input
        })

    idem_key =
      "k" <>
        Canonical.hash(%{
          "g" => state["graph_id"],
          "v" => state["graph_version"],
          "n" => id,
          "i" => input
        })

    {attempt_id, idem_key}
  end

  # --- events ---------------------------------------------------------------

  defp handle_result(graph, state, attempt_id, outcome, output, error_code, now) do
    case find_by_attempt(state, attempt_id) do
      nil ->
        # Duplicate or stale callback (e.g. after a crash): the attempt is no
        # longer current, so this is a no-op. Recording stays exactly-once per
        # attempt_id at the storage layer.
        {state, [{:noop}]}

      {id, node} ->
        if outcome == :ok do
          node = %{
            node
            | "status" => "completed",
              "output" => output,
              "attempt_id" => nil,
              "blocked" => nil
          }

          state = touch(put_node(state, id, node))
          state = %{state | "completed_order" => state["completed_order"] ++ [id]}
          schedule(graph, state, now)
        else
          max = get_in(graph, ["nodes", id, "retry", "max_attempts"]) || 1

          if node["attempts"] < max do
            delay = retry_delay(graph, id, node)
            timer_id = id <> ":retry:" <> Integer.to_string(node["attempts"] + 1)

            blocked = %{
              "reason" => "timer",
              "timer" => timer_id,
              "at" => now + delay,
              "since" => iso(now),
              "retry" => true
            }

            node = %{node | "status" => "blocked", "attempt_id" => nil, "blocked" => blocked}
            {touch(put_node(state, id, node)), [{:timer, timer_id, now + delay}]}
          else
            failure_path(
              graph,
              touch(put_node(state, id, %{node | "status" => "failed", "blocked" => nil})),
              id,
              error_code || "2001",
              now
            )
          end
        end
    end
  end

  defp handle_timer(graph, state, timer_id, now) do
    case Enum.find(state["nodes"], fn {_id, n} ->
           n["blocked"] != nil and n["blocked"]["reason"] == "timer" and
             n["blocked"]["timer"] == timer_id
         end) do
      nil ->
        {state, [{:noop}]}

      {id, node} ->
        if node["blocked"]["retry"] do
          node_def = graph["nodes"][id]

          input =
            Map.get(state["vars"], "input:" <> id, (node_def["config"] || %{})["input"] || %{})

          {st, action} = invoke_node(graph, state, id, input, now)
          {st, [action]}
        else
          node = %{
            node
            | "status" => "completed",
              "output" => %{"fired_at" => iso(now)},
              "blocked" => nil,
              "attempt_id" => nil
          }

          state = touch(put_node(state, id, node))
          state = %{state | "completed_order" => state["completed_order"] ++ [id]}
          schedule(graph, state, now)
        end
    end
  end

  defp handle_signal(graph, state, name, payload, now) do
    case Enum.find(state["nodes"], fn {_id, n} ->
           n["blocked"] != nil and n["blocked"]["reason"] == "signal" and
             n["blocked"]["signal"] == name
         end) do
      nil ->
        {state, [{:noop}]}

      {id, node} ->
        node_def = graph["nodes"][id]
        match = (node_def["config"] || %{})["match"]

        if when_matches?(match, payload) do
          node = %{
            node
            | "status" => "completed",
              "output" => payload,
              "blocked" => nil,
              "attempt_id" => nil
          }

          state = touch(put_node(state, id, node))
          state = %{state | "completed_order" => state["completed_order"] ++ [id]}
          schedule(graph, state, now)
        else
          {state, [{:noop}]}
        end
    end
  end

  defp handle_child(graph, state, child_id, child_status, now) do
    case Enum.find(state["nodes"], fn {_id, n} ->
           n["blocked"] != nil and n["blocked"]["reason"] == "child" and
             n["blocked"]["child"] == child_id
         end) do
      nil ->
        {state, [{:noop}]}

      {id, node} ->
        if child_status == "completed" do
          node = %{
            node
            | "status" => "completed",
              "output" => %{"child_id" => child_id},
              "blocked" => nil
          }

          state = touch(put_node(state, id, node))
          state = %{state | "completed_order" => state["completed_order"] ++ [id]}
          schedule(graph, state, now)
        else
          failure_path(
            graph,
            touch(put_node(state, id, %{node | "status" => "failed", "blocked" => nil})),
            id,
            "2001",
            now
          )
        end
    end
  end

  # --- failure and compensation (DECISIONS.md D-009) -------------------------

  defp failure_path(graph, state, id, code, now) do
    comp_map = graph["compensation"] || %{}

    pending =
      (Enum.reverse(state["completed_order"]) ++ [id])
      |> Enum.uniq()
      |> Enum.map(fn nid -> comp_map[nid] || graph["nodes"][nid]["compensation"] end)
      |> Enum.filter(& &1)
      |> Enum.uniq()

    if pending == [] do
      {%{state | "status" => "failed"}, [{:fail, code, now}]}
    else
      state = %{
        state
        | "status" => "compensating",
          "compensation" => %{"pending" => pending, "done" => %{}, "code" => code}
      }

      start_next_compensation(graph, state, now)
    end
  end

  defp start_next_compensation(graph, state, now) do
    comp = state["compensation"]

    case comp["pending"] do
      [] ->
        {%{state | "status" => "failed"}, [{:fail, comp["code"], now}]}

      [target | rest] ->
        node_def = graph["nodes"][target]
        input = (node_def["config"] || %{})["input"] || %{}
        {st, action} = invoke_node(graph, state, target, input, now)
        {%{st | "compensation" => %{comp | "pending" => rest}}, [action]}
    end
  end

  defp handle_comp_result(graph, state, attempt_id, outcome, output, error_code, now) do
    case find_by_attempt(state, attempt_id) do
      nil ->
        {state, [{:noop}]}

      {id, node} ->
        comp = state["compensation"]
        max = get_in(graph, ["nodes", id, "retry", "max_attempts"]) || 1

        cond do
          outcome == :ok ->
            comp = %{comp | "done" => Map.put(comp["done"], id, "ok")}

            node = %{
              node
              | "status" => "completed",
                "output" => output,
                "attempt_id" => nil,
                "blocked" => nil
            }

            state = %{state | "compensation" => comp}
            state = touch(put_node(state, id, node))
            state = %{state | "completed_order" => state["completed_order"] ++ [id]}
            start_next_compensation(graph, state, now)

          node["attempts"] < max ->
            delay = retry_delay(graph, id, node)
            timer_id = id <> ":retry:" <> Integer.to_string(node["attempts"] + 1)

            blocked = %{
              "reason" => "timer",
              "timer" => timer_id,
              "at" => now + delay,
              "since" => iso(now),
              "retry" => true
            }

            node = %{node | "status" => "blocked", "attempt_id" => nil, "blocked" => blocked}
            {touch(put_node(state, id, node)), [{:timer, timer_id, now + delay}]}

          true ->
            comp = %{
              comp
              | "done" => Map.put(comp["done"], id, "failed:" <> (error_code || "2001"))
            }

            node = %{node | "status" => "failed", "attempt_id" => nil, "blocked" => nil}
            state = %{state | "compensation" => comp}
            state = touch(put_node(state, id, node))
            start_next_compensation(graph, state, now)
        end
    end
  end

  # --- resume ----------------------------------------------------------------

  defp resume(graph, state, now) do
    {_state, actions} =
      Enum.reduce(state["nodes"], {state, []}, fn {id, node}, {st, acc} ->
        case node["status"] do
          "running" ->
            node_def = graph["nodes"][id]

            input =
              Map.get(st["vars"], "input:" <> id, (node_def["config"] || %{})["input"] || %{})

            timeout_s = node_def["timeout_s"] || 300

            action =
              {:invoke, id, node["attempt_id"], node["idempotency_key"], input,
               now + timeout_s * 1000}

            {st, acc ++ [action]}

          "blocked" ->
            case node["blocked"]["reason"] do
              "timer" -> {st, acc ++ [{:timer, node["blocked"]["timer"], node["blocked"]["at"]}]}
              _ -> {st, acc ++ [{:noop}]}
            end

          _ ->
            {st, acc}
        end
      end)

    {touch(state), actions}
  end

  # --- helpers ---------------------------------------------------------------

  defp check_terminal(graph, state, now, actions) do
    reachable = reachable_from_entry(graph)

    if state["status"] == "running" and
         Enum.all?(reachable, fn id -> state["nodes"][id]["status"] == "completed" end) do
      {%{state | "status" => "completed"}, actions ++ [{:complete, now}]}
    else
      {state, actions}
    end
  end

  # Compensation-only nodes are not reachable via edges; they must not block
  # termination.
  defp reachable_from_entry(graph) do
    graph["edges"]
    |> Enum.reduce(MapSet.new([graph["entry"]]), fn e, acc ->
      if MapSet.member?(acc, e["from"]), do: MapSet.put(acc, e["to"]), else: acc
    end)
    |> MapSet.to_list()
  end

  defp find_by_attempt(state, attempt_id) do
    Enum.find(state["nodes"], fn {_id, n} -> n["attempt_id"] == attempt_id end)
  end

  defp retry_delay(graph, id, node) do
    retry = get_in(graph, ["nodes", id, "retry"]) || %{}
    base = retry["backoff_ms"] || 1000

    delay =
      case retry["backoff"] do
        "exponential" -> base * round(:math.pow(2, node["attempts"]))
        _ -> base
      end

    if retry["jitter"] do
      delay + rem(:erlang.phash2(node["attempt_id"] || id), max(base, 1))
    else
      delay
    end
  end

  defp put_node(state, id, node), do: %{state | "nodes" => Map.put(state["nodes"], id, node)}

  defp touch(state), do: %{state | "blocked_on" => recompute_blocked_on(state)}

  defp recompute_blocked_on(state) do
    case Enum.find(state["nodes"], fn {_id, n} -> n["blocked"] != nil end) do
      nil ->
        nil

      {id, n} ->
        %{"node" => id, "reason" => n["blocked"]["reason"], "since" => n["blocked"]["since"]}
    end
  end

  defp parse_rfc3339!(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} ->
        DateTime.to_unix(dt, :millisecond)

      other ->
        raise ArgumentError, "invalid RFC 3339 timestamp: #{inspect(s)} (#{inspect(other)})"
    end
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
