defmodule Maat.Property.FencingTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  property "a zombie writer (stale expected version) can never commit" do
    check all(n <- integer(1..100)) do
      key = "fence/#{System.unique_integer([:positive])}"

      :ok = Maat.Storage.Memory.put("maat", key, "v0", 0)
      Enum.each(1..n, fn i -> :ok = Maat.Storage.Memory.put("maat", key, "v#{i}", i) end)
      current = n + 1

      for stale <- 0..n do
        assert {:conflict, ^current} = Maat.Storage.Memory.put("maat", key, "zombie", stale)
      end

      :ok = Maat.Storage.Memory.put("maat", key, "fresh", current)
      assert {:ok, {"fresh", new_v}} = Maat.Storage.Memory.get("maat", key)
      assert new_v == current + 1
    end
  end
end
