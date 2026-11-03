defmodule Maat do
  @moduledoc """
  Public API (SPECIFICATION.md section 9). M0 surface: graph registration,
  instance lifecycle, signals, executor result callbacks, event trail reads.
  """

  defp storage, do: Application.get_env(:maat, :storage, Maat.Storage.Memory)
  defp clock, do: Application.get_env(:maat, :clock, Maat.Clock.System)
  defp now, do: clock().now_ms()

  @doc """
  Submit a graph (map) or reference one (`{:ref, graph_id, version}`), then
  start an instance under `instance_id`. Returns `{:ok, pid, graph_id, version}`.
  """
  def start_instance(graph, instance_id, opts \\ []) do
    with {:ok, graph_id, version} <- register(graph, opts) do
      case Maat.Engine.Supervisor.start_instance(
             id: instance_id,
             graph_id: graph_id,
             version: version,
             vars: Keyword.get(opts, :vars, %{}),
             parent: opts[:parent],
             storage: storage(),
             clock: clock()
           ) do
        {:ok, pid} -> {:ok, pid, graph_id, version}
        other -> other
      end
    end
  end

  defp register(%{"api_version" => _} = graph, opts) do
    case Maat.Graph.Registry.put_spec(graph, manifests: Keyword.get(opts, :manifests, %{})) do
      {:ok, id, v} -> {:ok, id, v}
      {:error, code, msg} -> {:error, code, msg}
    end
  end

  defp register({:ref, id, v}, _opts), do: {:ok, id, v}

  @doc "Read persisted instance state. Returns `{:ok, state, version}` or `:not_found`."
  def get_instance(id) do
    case storage().get("maat", "instance/" <> id) do
      {:ok, {state, version}} -> {:ok, state, version}
      :not_found -> :not_found
    end
  end

  @doc "Deliver a named, typed signal to an instance."
  def signal(id, name, payload), do: deliver(id, {:signal, name, payload, now()})

  @doc "Executor callback: the outcome of one invocation attempt."
  def result(id, attempt_id, outcome, output \\ nil, error_code \\ nil),
    do: deliver(id, {:result, attempt_id, outcome, output, error_code, now()})

  @doc "Internal: a child instance finished."
  def child_result(id, child_id, status),
    do: deliver(id, {:child_result, child_id, status, now()})

  @doc "Append-only event trail for an instance."
  def events(id, opts \\ []), do: storage().events("maat", "instance/" <> id, opts)

  defp deliver(id, event) do
    case Registry.lookup(Maat.InstanceRegistry, id) do
      [{pid, _}] -> GenServer.call(pid, {:event, event}, 10_000)
      [] -> {:error, "4003", "instance not running"}
    end
  end
end
