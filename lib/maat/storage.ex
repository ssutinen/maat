defmodule Maat.Storage do
  @moduledoc """
  Storage behaviour — the only pluggable-truth surface (SPECIFICATION.md
  section 8, DECISIONS.md D-014).

  Semantics that must hold for every driver, including a future Ra-backed one:

  - leases carry a fencing token; only the current lease holder may write
  - every mutation is compare-and-swap on `version`; a stale writer always
    gets `{:conflict, current}` and can never commit
  - change notification is derived from the event trail via `scan/2`;
    `subscribe/2` is a best-effort hint, never load-bearing
  """

  @callback get(ns :: String.t(), key :: String.t()) ::
              {:ok, {value :: term(), version :: integer()}} | :not_found
  @callback put(
              ns :: String.t(),
              key :: String.t(),
              value :: term(),
              expected_version :: integer()
            ) ::
              :ok | {:conflict, current :: integer()} | {:error, code :: String.t()}
  @callback append(ns :: String.t(), key :: String.t(), event :: map()) ::
              :ok | {:error, code :: String.t()}
  @callback events(ns :: String.t(), key :: String.t(), opts :: keyword()) :: [map()]
  @callback lease(ns :: String.t(), key :: String.t(), ttl_ms :: integer()) ::
              {:ok, lease :: map()} | {:taken, holder :: pid()}
  @callback renew(lease :: map(), ttl_ms :: integer()) :: :ok | {:lost, holder :: pid() | nil}
  @callback subscribe(ns :: String.t(), prefix :: String.t()) :: :ok
  @callback scan(prefix :: String.t(), since :: integer()) :: [map()]
end
