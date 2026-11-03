defmodule Maat.CanonicalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Maat.TestGenerators, only: [json_term: 0]

  @moduletag :property

  property "canonical round-trip is exact and byte-stable" do
    check all(t <- json_term()) do
      encoded = Maat.Canonical.encode!(t)
      assert encoded == Maat.Canonical.encode!(t)
      assert Maat.Canonical.decode!(encoded) == t
    end
  end

  test "keys are sorted" do
    assert Maat.Canonical.encode!(%{"b" => 1, "a" => %{"d" => 2, "c" => 3}}) ==
             ~s({"a":{"c":3,"d":2},"b":1})
  end

  test "floats are rejected" do
    assert_raise ArgumentError, fn -> Maat.Canonical.encode!(%{"x" => 1.5}) end
    assert_raise ArgumentError, fn -> Maat.Canonical.decode!(~s({"x":1.5})) end
  end

  test "decimal strings pass through untouched" do
    assert Maat.Canonical.encode!(%{"amount" => "4.20"}) == ~s({"amount":"4.20"})
  end

  test "hash is content-addressed" do
    h1 = Maat.Canonical.hash(%{"a" => 1, "b" => 2})
    h2 = Maat.Canonical.hash(%{"b" => 2, "a" => 1})
    assert h1 == h2
    assert h1 =~ ~r/^b[0-9a-f]{64}$/
  end
end
