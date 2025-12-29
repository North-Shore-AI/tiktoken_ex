defmodule TiktokenEx.CacheTest do
  use ExUnit.Case, async: false

  alias TiktokenEx.Cache

  setup do
    Cache.clear()
    :ok
  end

  test "get_or_load caches values" do
    assert {:ok, :value} = Cache.get_or_load(:key, fn -> {:ok, :value} end)

    assert {:ok, :value} =
             Cache.get_or_load(:key, fn -> {:error, :should_not_load} end)
  end

  test "get_or_load does not cache errors" do
    assert {:error, :boom} = Cache.get_or_load(:bad, fn -> {:error, :boom} end)
    assert {:error, :boom} = Cache.get_or_load(:bad, fn -> {:error, :boom} end)
  end
end
