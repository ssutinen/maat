defmodule Maat.Graph.Registry do
  @moduledoc """
  Content-addressed graph registry (SPECIFICATION.md section 4.1).

  `graph_id = "b" <> sha256(canonical JSON)`. Versions are immutable; each
  submission of the same spec returns the same id and a new version only when
  the content changed.
  """

  use GenServer

  alias Maat.Canonical
  alias Maat.Graph.Admission

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def put_spec(graph, opts \\ []), do: GenServer.call(__MODULE__, {:put_spec, graph, opts})

  def get(graph_id, version \\ :latest), do: get(__MODULE__, graph_id, version)
  def get(server, graph_id, version), do: GenServer.call(server, {:get, graph_id, version})

  @impl true
  def init(_opts), do: {:ok, %{specs: %{}}}

  @impl true
  def handle_call({:put_spec, graph, opts}, _from, s) do
    case Admission.validate(graph, opts) do
      :ok ->
        id = Canonical.hash(graph)
        entry = Map.get(s.specs, id, %{versions: %{}, latest: 0})

        if Map.has_key?(entry.versions, entry.latest) and
             Map.get(entry.versions, entry.latest) == graph do
          {:reply, {:ok, id, entry.latest}, s}
        else
          v = entry.latest + 1
          entry = %{versions: Map.put(entry.versions, v, graph), latest: v}
          {:reply, {:ok, id, v}, %{s | specs: Map.put(s.specs, id, entry)}}
        end

      {:error, code, msg} ->
        {:reply, {:error, code, msg}, s}
    end
  end

  def handle_call({:get, graph_id, version}, _from, s) do
    case Map.get(s.specs, graph_id) do
      nil ->
        {:reply, :not_found, s}

      entry ->
        v = if version == :latest, do: entry.latest, else: version

        case Map.get(entry.versions, v) do
          nil -> {:reply, :not_found, s}
          graph -> {:reply, graph, s}
        end
    end
  end
end
