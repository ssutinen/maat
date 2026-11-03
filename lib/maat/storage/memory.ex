defmodule Maat.Storage.Memory do
  @moduledoc """
  In-memory storage driver. Implements real fencing-token leases and CAS on
  `version`, so the property suites exercise the same semantics a Ra-backed
  driver would have (DECISIONS.md D-014). Includes a kill switch for crash
  injection in tests.

  A lease whose holder process is dead is treated as expired, so a restarted
  instance can take over after a crash.
  """

  @behaviour Maat.Storage
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def get(ns, key), do: GenServer.call(__MODULE__, {:get, ns, key})

  @impl true
  def put(ns, key, value, expected_version),
    do: GenServer.call(__MODULE__, {:put, ns, key, value, expected_version})

  @impl true
  def append(ns, key, event), do: GenServer.call(__MODULE__, {:append, ns, key, event})

  @impl true
  def events(ns, key, opts \\ []), do: GenServer.call(__MODULE__, {:events, ns, key, opts})

  @impl true
  def lease(ns, key, ttl_ms), do: GenServer.call(__MODULE__, {:lease, ns, key, ttl_ms})

  @impl true
  def renew(lease, ttl_ms), do: GenServer.call(__MODULE__, {:renew, lease, ttl_ms})

  @impl true
  def subscribe(_ns, _prefix), do: :ok

  @impl true
  def scan(prefix, since), do: GenServer.call(__MODULE__, {:scan, prefix, since})

  @doc "Test hook: install a kill switch. `fun.(op)` returning `:boom` makes that op fail with 5001."
  def arm_kill_switch(fun) when is_function(fun, 1), do: GenServer.call(__MODULE__, {:arm, fun})
  def disarm_kill_switch, do: GenServer.call(__MODULE__, {:arm, nil})

  @impl true
  def init(opts) do
    {:ok,
     %{
       data: %{},
       events: [],
       seq: 0,
       leases: %{},
       fencing: 0,
       clock: Keyword.get(opts, :clock, Maat.Clock.System),
       kill_switch: Keyword.get(opts, :kill_switch, nil)
     }}
  end

  defp boom?(s, op), do: s.kill_switch != nil and s.kill_switch.(op) == :boom

  defp now_ms(s), do: s.clock.now_ms()

  @impl true
  def handle_call({:get, ns, key}, _from, s) do
    case s.data do
      %{{^ns, ^key} => {v, ver}} -> {:reply, {:ok, {v, ver}}, s}
      _ -> {:reply, :not_found, s}
    end
  end

  def handle_call({:put, ns, key, value, expected}, _from, s) do
    if boom?(s, :put) do
      {:reply, {:error, "5001"}, s}
    else
      current =
        case s.data do
          %{{^ns, ^key} => {_, ver}} -> ver
          _ -> 0
        end

      if current == expected do
        {:reply, :ok, %{s | data: Map.put(s.data, {ns, key}, {value, current + 1})}}
      else
        {:reply, {:conflict, current}, s}
      end
    end
  end

  def handle_call({:append, ns, key, event}, _from, s) do
    if boom?(s, :append) do
      {:reply, {:error, "5001"}, s}
    else
      seq = s.seq + 1
      {:reply, :ok, %{s | seq: seq, events: s.events ++ [{seq, ns, key, event}]}}
    end
  end

  def handle_call({:events, ns, key, opts}, _from, s) do
    list =
      for {seq, ^ns, ^key, ev} <- s.events do
        %{seq: seq, event: ev}
      end

    list = if opts[:reverse], do: Enum.reverse(list), else: list
    list = if opts[:limit], do: Enum.take(list, opts[:limit]), else: list
    {:reply, list, s}
  end

  def handle_call({:lease, ns, key, ttl}, {holder, _ref} = _from, s) do
    now = now_ms(s)
    existing = Map.get(s.leases, {ns, key})

    if existing && existing.expires_at > now && Process.alive?(existing.holder) do
      {:reply, {:taken, existing.holder}, s}
    else
      fencing = s.fencing + 1
      lease = %{ns: ns, key: key, holder: holder, fencing: fencing, expires_at: now + ttl}
      {:reply, {:ok, lease}, %{s | fencing: fencing, leases: Map.put(s.leases, {ns, key}, lease)}}
    end
  end

  def handle_call({:renew, lease, ttl}, _from, s) do
    now = now_ms(s)
    current = Map.get(s.leases, {lease.ns, lease.key})

    if current && current.fencing == lease.fencing && current.holder == lease.holder &&
         current.expires_at > now do
      renewed = %{current | expires_at: now + ttl}
      {:reply, :ok, %{s | leases: Map.put(s.leases, {lease.ns, lease.key}, renewed)}}
    else
      {:reply, {:lost, current && current.holder}, s}
    end
  end

  def handle_call({:scan, prefix, since}, _from, s) do
    now = now_ms(s)

    entries =
      for {seq, ns, key, ev} <- s.events, seq > since, String.starts_with?(key, prefix) do
        base = %{seq: seq, ns: ns, key: key, kind: ev["kind"], event: ev}

        if ev["kind"] == "timer" && ev["at"] <= now do
          [base, %{seq: seq, ns: ns, key: key, kind: "timer_due", id: ev["id"], at: ev["at"]}]
        else
          [base]
        end
      end
      |> List.flatten()

    {:reply, entries, s}
  end

  def handle_call({:arm, fun}, _from, s), do: {:reply, :ok, %{s | kill_switch: fun}}
end
