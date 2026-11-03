defmodule Maat.Graph.Admission do
  @moduledoc """
  Admission-time validation and lint (SPECIFICATION.md section 4.1).

  JSON Schema validation plus deterministic lint, rejected fail-fast with
  stable 3xxx codes — never at runtime. `opts[:manifests]` maps node kind to
  its registered manifest; `opts[:schemas_dir]` overrides the schema location.
  """

  alias Maat.Engine.Interpreter

  def validate(graph, opts \\ []) do
    schemas_dir = Keyword.get(opts, :schemas_dir, Maat.Schemas.dir())
    manifests = Keyword.get(opts, :manifests, %{})

    with :ok <- schema_validate(graph, schemas_dir),
         :ok <- check_refs(graph, schemas_dir),
         :ok <- check_predicates(graph),
         :ok <- check_kinds(graph, manifests),
         :ok <- check_compensation(graph, manifests),
         :ok <- check_reachable(graph),
         :ok <- check_no_comp_of_comp(graph) do
      :ok
    end
  end

  defp err(code, msg), do: {:error, code, msg}

  defp schema_validate(graph, schemas_dir) do
    schema = schemas_dir |> Path.join("graph.schema.json") |> File.read!() |> Jason.decode!()

    case ExJsonSchema.Validator.validate(schema, graph) do
      :ok -> :ok
      {:error, errors} -> err("3001", "invalid graph: #{inspect(errors)}")
    end
  end

  # Unresolvable $refs in node input/output schemas are admission failures.
  defp check_refs(graph, schemas_dir) do
    Enum.find_value(graph["nodes"], :ok, fn {_id, node} ->
      Enum.find_value([node["inputs"], node["outputs"]], :ok, fn
        %{"$ref" => ref} ->
          if File.exists?(Path.join(schemas_dir, ref)),
            do: :ok,
            else: err("3001", "unresolvable schema ref: #{ref}")

        _ ->
          :ok
      end)
    end)
  end

  # `when` predicates must be objects mapping output paths to scalar values.
  defp check_predicates(graph) do
    bad =
      Enum.any?(graph["edges"], fn e ->
        case e["when"] do
          nil ->
            false

          %{} = w ->
            Enum.any?(w, fn {_k, v} ->
              not is_binary(v) and not is_integer(v) and not is_boolean(v) and v != nil
            end)

          _ ->
            true
        end
      end)

    if bad, do: err("3001", "malformed predicate"), else: :ok
  end

  defp check_kinds(graph, manifests) do
    Enum.find_value(graph["nodes"], :ok, fn {id, node} ->
      kind = node["kind"]

      if Interpreter.effect_kind?(kind) or Map.has_key?(manifests, kind) do
        :ok
      else
        err("3002", "unknown node kind #{kind} (node #{id})")
      end
    end)
  end

  defp side_effects?(graph, manifests, id) do
    node = graph["nodes"][id]
    kind = node["kind"]

    cond do
      Map.has_key?(node, "side_effects") -> node["side_effects"]
      Interpreter.effect_kind?(kind) -> Interpreter.effect_side_effects(kind)
      true -> manifests[kind]["side_effects"] != false
    end
  end

  defp compensation_for(graph, id) do
    (graph["compensation"] || %{})[id] || graph["nodes"][id]["compensation"]
  end

  defp check_compensation(graph, manifests) do
    Enum.find_value(graph["nodes"], :ok, fn {id, node} ->
      if side_effects?(graph, manifests, id) and node["no_compensate"] != true and
           compensation_for(graph, id) == nil do
        err("3003", "node #{id} has side effects but no compensation and no no_compensate")
      else
        :ok
      end
    end)
  end

  defp check_reachable(graph) do
    comp_targets =
      (((graph["compensation"] || %{}) |> Map.values()) ++
         Enum.map(graph["nodes"], fn {_id, n} -> n["compensation"] end))
      |> Enum.filter(& &1)

    reachable =
      graph["edges"]
      |> Enum.reduce(MapSet.new([graph["entry"]]), fn e, acc ->
        if MapSet.member?(acc, e["from"]), do: MapSet.put(acc, e["to"]), else: acc
      end)

    unreachable =
      Map.keys(graph["nodes"])
      |> Enum.reject(fn id -> MapSet.member?(reachable, id) or id in comp_targets end)

    if unreachable == [], do: :ok, else: err("3004", "unreachable nodes: #{inspect(unreachable)}")
  end

  defp check_no_comp_of_comp(graph) do
    comp_map = graph["compensation"] || %{}

    targets =
      MapSet.new(
        (Map.values(comp_map) ++ Enum.map(graph["nodes"], fn {_id, n} -> n["compensation"] end))
        |> Enum.filter(& &1)
      )

    bad =
      Enum.any?(targets, fn t ->
        Map.has_key?(comp_map, t) or graph["nodes"][t]["compensation"] != nil
      end)

    if bad, do: err("3005", "compensation node declares its own compensation"), else: :ok
  end
end
