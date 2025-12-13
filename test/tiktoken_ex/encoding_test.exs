defmodule TiktokenEx.EncodingTest do
  use ExUnit.Case, async: true

  alias TiktokenEx.Encoding

  test "byte-pair merges follow lowest-rank-first with stable tie-breaking" do
    mergeable_ranks = %{
      "He" => 0,
      "ll" => 1,
      "llo" => 2,
      "H" => 10,
      "e" => 11,
      "l" => 12,
      "o" => 13
    }

    {:ok, enc} = Encoding.new(pat_str: ".+", mergeable_ranks: mergeable_ranks)

    assert {:ok, [0, 2]} == Encoding.encode(enc, "Hello")
    assert {:ok, "Hello"} == Encoding.decode(enc, [0, 2])
  end

  test "encode/decode supports special tokens when allowed" do
    mergeable_ranks = %{
      "He" => 0,
      "ll" => 1,
      "llo" => 2,
      "H" => 10,
      "e" => 11,
      "l" => 12,
      "o" => 13
    }

    special_tokens = %{"<|bos|>" => 14}

    {:ok, enc} =
      Encoding.new(
        pat_str: ".+",
        mergeable_ranks: mergeable_ranks,
        special_tokens: special_tokens
      )

    assert {:ok, [14, 0, 2]} == Encoding.encode(enc, "<|bos|>Hello", allow_special_tokens: true)
    assert {:ok, "<|bos|>Hello"} == Encoding.decode(enc, [14, 0, 2])
  end

  test "special token matching prefers the longest match when configured" do
    mergeable_ranks = %{"b" => 0}
    special_tokens = %{"<|a|>" => 100, "<|a|>b" => 101}

    {:ok, enc} =
      Encoding.new(
        pat_str: ".+",
        mergeable_ranks: mergeable_ranks,
        special_tokens: special_tokens,
        special_token_matching: :longest
      )

    assert {:ok, [101]} == Encoding.encode(enc, "<|a|>b", allow_special_tokens: true)
  end

  test "default special token matching is parity (unspecified order)" do
    mergeable_ranks = %{"b" => 0}
    special_tokens = %{"<|a|>" => 100, "<|a|>b" => 101}

    {:ok, enc} =
      Encoding.new(
        pat_str: ".+",
        mergeable_ranks: mergeable_ranks,
        special_tokens: special_tokens
      )

    assert enc.special_token_matching == :parity

    assert {:ok, ids} = Encoding.encode(enc, "<|a|>b", allow_special_tokens: true)
    assert ids in [[101], [100, 0]]
  end

  test "new/1 and decode/2 surface invalid input errors" do
    assert {:error, {:invalid_pat_str, _}} = Encoding.new(pat_str: "(", mergeable_ranks: %{})

    {:ok, enc} = Encoding.new(pat_str: ".+", mergeable_ranks: %{"a" => 0})

    assert {:error, {:invalid_token_id, "a"}} == Encoding.decode(enc, ["a"])
    assert {:error, {:unknown_token_id, 1}} == Encoding.decode(enc, [1])
  end
end
