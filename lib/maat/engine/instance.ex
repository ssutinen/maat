defmodule Maat.Engine.Instance do
  @moduledoc """
  One supervised GenServer per instance key (SPECIFICATION.md sections 3, 5).

  Every event is applied through the pure interpreter, persisted with a
  compare-and-swap on `version`, and only then do actions execute. A process
  that died mid-flight and briefly resumes loses on the first write (4001)
  and terminates. On restart the supervisor re-reads state from storage and
  re-derives pending actions with `{:resume, now}` — resume is a read.
  """

  use GenServer
  require Logger

  alias Maat.Engine.Interpreter

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Maat.InstanceRegistry, opts[:id]}}
    )
  end

  def child_spec(opts) do
    %{super(opts) | id: opts[:id]}
  end

  defp storage(opts),
    do: Keyword.get(opts, :storage, Application.get_env(:maat, :storage, Maat.Storage.Memory))

  defp clock(opts),
    do: Keyword.get(opts, :clock, Application.get_env(:maat, :clock, Maat.Clock.System))

  @impl true
  def init(opts) do
    id = opts[:id]
    storage = storage(opts)
    clock = clock(opts)
    graph_registry = Keyword.get(opts, :graph_registry, Maat.Graph.Registry)
    ns = "maat"
    key = "instance/" <> id
    ttl = Keyword.get(opts, :lease_ttl_ms, Application.get_env(:maat, :lease_ttl_ms, 30_000))

    with {:ok, graph} <- fetch_graph(graph_registry, opts),
         {:ok, lease} <- storage.lease(ns, key, ttl) do
      st = %{
        id: id,
        graph: graph,
        graph_id: opts[:graph_id],
        version_id: opts[:version],
        ns: ns,
        key: key,
        lease: lease,
        storage: storage,
        clock: clock,
        opts: opts,
        state: nil,
        version: 0
      }

      Process.send_after(self(), :renew_lease, div(ttl, 3))

      case storage.get(ns, key) do
        :not_found ->
          st = %{
            st
            | state:
                Interpreter.init(
                  graph,
                  opts[:graph_id],
                  opts[:version],
                  Keyword.get(opts, :vars, %{})
                )
          }

          apply_event(st, {:start, clock.now_ms()})

        {:ok, {state, version}} ->
          st = %{st | state: state, version: version}
          apply_event(st, {:resume, clock.now_ms()})
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp fetch_graph(graph_registry, opts) do
    case Maat.Graph.Registry.get(graph_registry, opts[:graph_id], opts[:version]) do
      :not_found -> {:error, :graph_not_found}
      graph -> {:ok, graph}
    end
  end

  @impl true
  def handle_call({:event, event}, _from, st) do
    case apply_event(st, event) do
      {:ok, st} ->
        if terminal?(st.state) do
          notify_parent(st)
          {:stop, :normal, :ok, st}
        else
          {:reply, :ok, st}
        end

      {:stop, reason} ->
        {:stop, reason, {:error, reason}, st}
    end
  end

  @impl true
  def handle_info(:renew_lease, st) do
    ttl = Keyword.get(st.opts, :lease_ttl_ms, Application.get_env(:maat, :lease_ttl_ms, 30_000))

    case st.storage.renew(st.lease, ttl) do
      :ok ->
        Process.send_after(self(), :renew_lease, div(ttl, 3))
        {:noreply, st}

      {:lost, _holder} ->
        {:stop, {:lease_lost, "4002"}, st}
    end
  end

  defp terminal?(state), do: state["status"] in ["completed", "failed"]

  # Apply one event: decide (pure) -> persist (CAS) -> execute actions.
  defp apply_event(st, event) do
    now = st.clock.now_ms()
    {state2, actions} = Interpreter.decide(st.graph, st.state, event)

    case st.storage.put(st.ns, st.key, state2, st.version) do
      :ok ->
        st.storage.append(st.ns, st.key, %{
          "kind" => "event",
          "event" => event |> elem(0) |> to_string(),
          "at" => now,
          "v" => st.version + 1
        })

        st = %{st | state: state2, version: st.version + 1}
        execute_actions(st, actions, now)
        {:ok, st}

      {:conflict, current} ->
        Logger.warning("instance #{st.id} fenced on write (4001), current version #{current}")
        {:stop, {:fenced, "4001", current}}

      {:error, code} ->
        {:stop, {:storage_error, code}}
    end
  end

  defp execute_actions(st, actions, now) do
    Enum.each(actions, fn action -> execute_action(st, action, now) end)
  end

  defp execute_action(st, action, now) do
    case action do
      {:invoke, node, attempt_id, idem_key, input, deadline} ->
        st.storage.append(st.ns, st.key, %{
          "kind" => "dispatched",
          "node" => node,
          "attempt_id" => attempt_id,
          "idempotency_key" => idem_key,
          "input" => input,
          "deadline" => deadline,
          "at" => now
        })

        if bridge = st.opts[:bridge], do: bridge.invoke(st.id, action)

      {:timer, id, at} ->
        st.storage.append(st.ns, st.key, %{"kind" => "timer", "id" => id, "at" => at})

      {:emit, ev} ->
        st.storage.append(st.ns, st.key, Map.merge(%{"kind" => "emit", "at" => now}, ev))

      {:enqueue, _node, child_id, graph_ref, input} ->
        Maat.Engine.Supervisor.start_instance(
          id: child_id,
          graph_id: graph_ref,
          version: :latest,
          vars: input,
          parent: st.id,
          storage: st.storage,
          clock: st.clock
        )

      {:complete, _} ->
        st.storage.append(st.ns, st.key, %{
          "kind" => "terminal",
          "status" => "completed",
          "at" => now
        })

      {:fail, code, _} ->
        st.storage.append(st.ns, st.key, %{
          "kind" => "terminal",
          "status" => "failed",
          "code" => code,
          "at" => now
        })

      {:noop} ->
        :ok
    end
  end

  defp notify_parent(st) do
    if parent = st.opts[:parent] do
      case Registry.lookup(Maat.InstanceRegistry, parent) do
        [{pid, _}] ->
          GenServer.call(
            pid,
            {:event, {:child_result, st.id, st.state["status"], st.clock.now_ms()}},
            5_000
          )

        [] ->
          :ok
      end
    end
  end
end
