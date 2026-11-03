defmodule Maat.Canonical do
  @moduledoc """
  Canonical JSON encoding (SPECIFICATION.md section 9.4).

  Sorted keys, UTF-8, numbers are integers or decimal strings (`"4.20"`),
  timestamps are RFC 3339 strings, no binary blobs, no floats. Floats are
  rejected loudly: exactness is what makes hashing and diffs stable.
  """

  @doc "Encode a term to canonical JSON. Raises on floats or non-string map keys."
  def encode!(term), do: term |> normalize!() |> do_encode() |> IO.iodata_to_binary()

  @doc "Decode canonical JSON. Raises on floats."
  def decode!(binary), do: binary |> Jason.decode!() |> normalize!()

  @doc "Reject floats and non-string keys anywhere in the term."
  def normalize!(term) when is_float(term),
    do: raise(ArgumentError, "floats are not allowed in canonical JSON: #{term}")

  def normalize!(term) when is_map(term) do
    Map.new(term, fn
      {k, v} when is_binary(k) -> {k, normalize!(v)}
      {k, _} -> raise ArgumentError, "map keys must be strings, got: #{inspect(k)}"
    end)
  end

  def normalize!(term) when is_list(term), do: Enum.map(term, &normalize!/1)
  def normalize!(term) when is_binary(term), do: term
  def normalize!(term) when is_integer(term), do: term
  def normalize!(term) when is_boolean(term), do: term
  def normalize!(nil), do: nil

  @doc "Content address: `\"b\" <> sha256 hex of the canonical encoding`."
  def hash(term), do: "b" <> Base.encode16(:crypto.hash(:sha256, encode!(term)), case: :lower)

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(i) when is_integer(i), do: Integer.to_string(i)
  defp do_encode(s) when is_binary(s), do: Jason.encode!(s)

  defp do_encode(list) when is_list(list),
    do: ["[", Enum.map_join(list, ",", &do_encode/1), "]"]

  defp do_encode(map) when is_map(map) do
    body =
      map
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join(",", fn {k, v} -> [Jason.encode!(k), ":", do_encode(v)] end)

    ["{", body, "}"]
  end
end
