import Config

config :maat,
  storage: Maat.Storage.Memory,
  clock: Maat.Clock.System,
  sweeper_interval_ms: 1_000,
  lease_ttl_ms: 30_000

if Mix.env() == :test do
  # Property tests drive the sweeper manually via Sweeper.tick/1, use the fake
  # clock, and kill instance processes repeatedly on purpose, so supervisors
  # must not give up on restarts.
  config :maat,
    clock: Maat.FakeClock,
    sweeper_interval_ms: 60_000,
    max_restarts: 1_000_000,
    max_seconds: 1,
    # The fake clock can jump far ahead; leases must never expire mid-test.
    lease_ttl_ms: 100_000_000_000
end
