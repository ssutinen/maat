defmodule Maat.Codes do
  @moduledoc """
  Stable diagnostic codes (SPECIFICATION.md section 9.5). Codes are part of the
  public API: agents may branch on them; they are never reordered or renumbered.
  The canonical list lives in `schemas/codes.json`.
  """

  def all, do: Maat.Schemas.load("codes.json")["codes"]

  def message(code) do
    Enum.find_value(all(), fn c -> if c["code"] == code, do: c["message"] end)
  end
end
