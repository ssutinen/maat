defmodule Maat.Engine.Lease do
  @moduledoc """
  Fencing lease wrapper over the storage behaviour. The lease map carries a
  monotonically increasing `fencing` token; combined with compare-and-swap on
  `version`, a zombie writer can never commit (property-tested).
  """

  def acquire(storage, ns, key, ttl_ms), do: storage.lease(ns, key, ttl_ms)
  def renew(storage, lease, ttl_ms), do: storage.renew(lease, ttl_ms)
  def fencing_token(lease), do: lease.fencing
end
