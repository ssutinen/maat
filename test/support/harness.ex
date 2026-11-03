defmodule Maat.TestHarness do
  @moduledoc """
  Shared harness for property tests. `pure_run` drives the interpreter
  directly; `live_run` drives a real supervised instance process with crash
  injection. Both consume the same script, so their final states must be
  byte-identical.
  """

  alias Maat.Engine.Interpreter
  import Maat.TestGenerators, only: [start_ms: 0]

  @max_drain 200

  # --- pure reference --------------------------------------------------------

  def pure_run(graph, graph_id, graph_version, script, seed) do
    :rand.seed(:exsss, seed)
    state0 = Interpreter.init(graph, graph_id, graph_version, %{})
    {st1, _actions} = Interpreter.decide(graph, state0, {:start, start_ms()})
    {st2, now} = drain_pure(graph, st1, start_ms())

    {state, _now} =
      Enum.reduce(script, {st2, now}, fn step, {st, now} ->
        {st, now} = pure_step(graph, st, step, now)
        drain_pure(graph, st, now)
      end)

    state
  end

  defp pure_step(graph, st, step, now) do
    case step do
      {:respond, id, outcome} ->
        node = st["nodes"][id]

        if node && node["status"] == "running" do
          {Interpreter.decide(graph, st, {:result, node["attempt_id"], outcome, %{}, nil, now})
           |> elem(0), now}
        else
          {st, now}
        end

      {:signal, name, payload} ->
        {Interpreter.decide(graph, st, {:signal, name, payload, now}) |> elem(0), now}

      {:advance, ms} ->
        {st, now + ms}

      {:kill} ->
        {Interpreter.decide(graph, st, {:resume, now}) |> elem(0), now}

      {:noop} ->
        {st, now}
    end
  end

  defp drain_pure(graph, st, now) do
    Enum.reduce_while(1..@max_drain, {st, now}, fn _, {st, now} ->
      if st["status"] in ["completed", "failed"] do
        {:halt, {st, now}}
      else
        case drain_action_pure(graph, st, now) do
          nil -> {:halt, {st, now}}
          {st2, now2} -> {:cont, {st2, now2}}
        end
      end
    end)
  end

  defp drain_action_pure(graph, st, now) do
    running = Enum.find(st["nodes"], fn {_id, n} -> n["status"] == "running" end)

    timer =
      Enum.find(st["nodes"], fn {_id, n} ->
        n["blocked"] != nil and n["blocked"]["reason"] == "timer"
      end)

    sig =
      Enum.find(st["nodes"], fn {_id, n} ->
        n["blocked"] != nil and n["blocked"]["reason"] == "signal"
      end)

    cond do
      running != nil ->
        {_id, node} = running

        {Interpreter.decide(graph, st, {:result, node["attempt_id"], :ok, %{}, nil, now})
         |> elem(0), now}

      timer != nil ->
        {_id, node} = timer
        now2 = max(now, node["blocked"]["at"])
        {Interpreter.decide(graph, st, {:timer, node["blocked"]["timer"], now2}) |> elem(0), now2}

      sig != nil ->
        {_id, node} = sig

        {Interpreter.decide(graph, st, {:signal, node["blocked"]["signal"], %{}, now}) |> elem(0),
         now}

      true ->
        nil
    end
  end

  # --- live run with crash injection ------------------------------------------

  def live_run(_graph, graph_id, graph_version, script, seed, manifests) do
    :rand.seed(:exsss, seed)
    iid = "t#{System.unique_integer([:positive])}"

    {:ok, _pid, _gid, _v} =
      Maat.start_instance({:ref, graph_id, graph_version}, iid, manifests: manifests)

    Maat.FakeClock.set(start_ms())
    now0 = drain_live(iid, start_ms())

    {now, versions} =
      Enum.reduce(script, {now0, []}, fn step, {now, vs} ->
        now = live_step(iid, step, now)
        {:ok, _st, ver} = Maat.get_instance(iid)
        {now, vs ++ [ver]}
      end)

    drain_live(iid, now)
    {:ok, st, _ver} = Maat.get_instance(iid)
    {st, versions}
  end

  defp live_step(iid, step, now) do
    case step do
      {:respond, id, outcome} ->
        case Maat.get_instance(iid) do
          {:ok, st, _} ->
            node = st["nodes"][id]

            if node && node["status"] == "running" do
              deliver_retry(iid, {:result, node["attempt_id"], outcome, %{}, nil, now})
            end

          :not_found ->
            :ok
        end

        now

      {:signal, name, payload} ->
        deliver_retry(iid, {:signal, name, payload, now})
        now

      {:advance, ms} ->
        Maat.FakeClock.advance(ms)
        Maat.Engine.Sweeper.tick()
        now + ms

      {:kill} ->
        case Registry.lookup(Maat.InstanceRegistry, iid) do
          [{pid, _}] ->
            Process.exit(pid, :kill)
            wait_restart(iid)

          [] ->
            :ok
        end

        now

      {:noop} ->
        now
    end
  end

  defp deliver_retry(iid, event) do
    Enum.find_value(1..100, fn _ ->
      if terminal_in_storage?(iid) do
        :done
      else
        case Registry.lookup(Maat.InstanceRegistry, iid) do
          [{pid, _}] ->
            if Process.alive?(pid) do
              try do
                GenServer.call(pid, {:event, event}, 1_000)
                :done
              rescue
                _ -> Process.sleep(2)
              catch
                :exit, _ -> Process.sleep(2)
              end
            else
              Process.sleep(2)
            end

          [] ->
            Process.sleep(2)
        end
      end
    end)
  end

  defp terminal_in_storage?(iid) do
    case Maat.get_instance(iid) do
      {:ok, st, _} -> st["status"] in ["completed", "failed"]
      :not_found -> false
    end
  end

  defp wait_restart(iid) do
    Enum.find_value(1..100, fn _ ->
      Process.sleep(2)

      if terminal_in_storage?(iid) do
        :done
      else
        case Registry.lookup(Maat.InstanceRegistry, iid) do
          [{pid, _}] -> if Process.alive?(pid), do: pid
          [] -> nil
        end
      end
    end)
  end

  defp drain_live(iid, now) do
    Enum.reduce_while(1..@max_drain, now, fn _, now ->
      case Maat.get_instance(iid) do
        {:ok, st, _ver} ->
          if st["status"] in ["completed", "failed"] do
            {:halt, now}
          else
            case drain_action_live(iid, st, now) do
              nil -> {:halt, now}
              now2 -> {:cont, now2}
            end
          end

        :not_found ->
          {:halt, now}
      end
    end)
  end

  defp drain_action_live(iid, st, now) do
    running = Enum.find(st["nodes"], fn {_id, n} -> n["status"] == "running" end)

    timer =
      Enum.find(st["nodes"], fn {_id, n} ->
        n["blocked"] != nil and n["blocked"]["reason"] == "timer"
      end)

    sig =
      Enum.find(st["nodes"], fn {_id, n} ->
        n["blocked"] != nil and n["blocked"]["reason"] == "signal"
      end)

    cond do
      running != nil ->
        {_id, node} = running
        deliver_retry(iid, {:result, node["attempt_id"], :ok, %{}, nil, now})
        now

      timer != nil ->
        {_id, node} = timer
        now2 = max(now, node["blocked"]["at"])
        if now2 > now, do: Maat.FakeClock.advance(now2 - now)
        Maat.Engine.Sweeper.tick()
        now2

      sig != nil ->
        {_id, node} = sig
        deliver_retry(iid, {:signal, node["blocked"]["signal"], %{}, now})
        now

      true ->
        nil
    end
  end
end
