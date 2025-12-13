defmodule TiktokenEx.Encoding do
  @moduledoc """
  A TikToken-style encoding: regex-based splitting + byte-pair encoding + specials.
  """

  @type token_id :: non_neg_integer()

  @type t :: %__MODULE__{
          pat_str: String.t(),
          pat_regex: Regex.t(),
          mergeable_ranks: %{required(binary()) => token_id()},
          decoder: %{required(token_id()) => binary()},
          special_tokens: %{required(String.t()) => token_id()},
          special_tokens_by_id: %{required(token_id()) => String.t()},
          special_regex: Regex.t() | nil
        }

  defstruct [
    :pat_str,
    :pat_regex,
    :mergeable_ranks,
    :decoder,
    :special_tokens,
    :special_tokens_by_id,
    :special_regex
  ]

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    pat_str = Keyword.fetch!(opts, :pat_str)
    mergeable_ranks = Keyword.fetch!(opts, :mergeable_ranks)
    special_tokens = Keyword.get(opts, :special_tokens, %{})

    with {:ok, pat_regex} <- compile_pat(pat_str),
         :ok <- validate_mergeable_ranks(mergeable_ranks),
         :ok <- validate_special_tokens(special_tokens),
         {:ok, decoder} <- invert_bytes_map(mergeable_ranks),
         {:ok, special_tokens_by_id} <- invert_special_tokens(special_tokens),
         {:ok, special_regex} <- compile_special_regex(special_tokens) do
      {:ok,
       %__MODULE__{
         pat_str: pat_str,
         pat_regex: pat_regex,
         mergeable_ranks: mergeable_ranks,
         decoder: decoder,
         special_tokens: special_tokens,
         special_tokens_by_id: special_tokens_by_id,
         special_regex: special_regex
       }}
    end
  end

  @spec encode(t(), String.t(), keyword()) :: {:ok, [token_id()]} | {:error, term()}
  def encode(%__MODULE__{} = encoding, text, opts \\ []) when is_binary(text) do
    allow_special_tokens = Keyword.get(opts, :allow_special_tokens, true)

    segments =
      if allow_special_tokens do
        split_special(encoding, text)
      else
        [{:text, text}]
      end

    segments
    |> Enum.reduce_while({:ok, []}, fn
      {:special, token}, {:ok, acc_rev} ->
        case Map.fetch(encoding.special_tokens, token) do
          {:ok, id} -> {:cont, {:ok, [id | acc_rev]}}
          :error -> {:halt, {:error, {:unknown_special_token, token}}}
        end

      {:text, segment}, {:ok, acc_rev} ->
        case encode_plain_segment(encoding, segment) do
          {:ok, ids} -> {:cont, {:ok, Enum.reverse(ids, acc_rev)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, ids_rev} -> {:ok, Enum.reverse(ids_rev)}
      other -> other
    end
  end

  @spec decode(t(), [token_id()]) :: {:ok, String.t()} | {:error, term()}
  def decode(%__MODULE__{} = encoding, ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc_rev} ->
      cond do
        not is_integer(id) ->
          {:halt, {:error, {:invalid_token_id, id}}}

        Map.has_key?(encoding.special_tokens_by_id, id) ->
          {:cont, {:ok, [encoding.special_tokens_by_id[id] | acc_rev]}}

        true ->
          case Map.fetch(encoding.decoder, id) do
            {:ok, bytes} -> {:cont, {:ok, [bytes | acc_rev]}}
            :error -> {:halt, {:error, {:unknown_token_id, id}}}
          end
      end
    end)
    |> case do
      {:ok, parts_rev} ->
        text =
          parts_rev
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> String.replace_invalid("�")

        {:ok, text}

      other ->
        other
    end
  end

  # Regex splitting

  defp split_special(%__MODULE__{special_regex: nil}, text), do: [{:text, text}]

  defp split_special(%__MODULE__{special_regex: %Regex{} = re}, text) do
    re
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn segment ->
      if Regex.match?(re, segment), do: {:special, segment}, else: {:text, segment}
    end)
  end

  defp encode_plain_segment(_encoding, ""), do: {:ok, []}

  defp encode_plain_segment(%__MODULE__{} = encoding, segment) do
    pieces =
      encoding.pat_regex
      |> Regex.scan(segment)
      |> Enum.map(&List.first/1)

    pieces
    |> Enum.reduce_while({:ok, []}, fn piece, {:ok, acc_rev} ->
      bytes = :unicode.characters_to_binary(piece, :utf8)

      case encode_bytes(encoding.mergeable_ranks, bytes) do
        {:ok, ids} -> {:cont, {:ok, Enum.reverse(ids, acc_rev)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids_rev} -> {:ok, Enum.reverse(ids_rev)}
      other -> other
    end
  end

  # BPE encoding

  defp encode_bytes(_ranks, <<>>), do: {:ok, []}

  defp encode_bytes(ranks, bytes) when is_map(ranks) and is_binary(bytes) do
    case Map.fetch(ranks, bytes) do
      {:ok, id} ->
        {:ok, [id]}

      :error ->
        merged_parts = bpe_merge(ranks, bytes)

        ids =
          Enum.map(merged_parts, fn part ->
            Map.fetch!(ranks, part)
          end)

        {:ok, ids}
    end
  rescue
    e in KeyError ->
      {:error, {:missing_rank, e.key}}
  end

  defp bpe_merge(_ranks, <<>>), do: []

  defp bpe_merge(ranks, bytes) when is_map(ranks) and is_binary(bytes) do
    # For small pieces, the simpler O(n^2) merge loop is typically faster due
    # to lower constant overhead.
    if byte_size(bytes) <= 128 do
      parts = for <<b <- bytes>>, do: <<b>>
      merge_parts_naive(ranks, parts)
    else
      merge_parts_heap(ranks, bytes)
    end
  end

  defp merge_parts_naive(ranks, parts) do
    case best_merge_pair_naive(ranks, parts) do
      nil ->
        parts

      {idx, _rank} ->
        merge_parts_naive(ranks, merge_at_naive(parts, idx))
    end
  end

  defp best_merge_pair_naive(ranks, parts) do
    do_best_merge_pair_naive(ranks, parts, 0, nil)
  end

  defp do_best_merge_pair_naive(_ranks, [_last], _idx, best), do: best

  defp do_best_merge_pair_naive(ranks, [a, b | rest], idx, best) do
    rank = Map.get(ranks, a <> b)

    best =
      cond do
        is_integer(rank) and best == nil ->
          {idx, rank}

        is_integer(rank) and match?({_, best_rank} when is_integer(best_rank), best) ->
          {_best_idx, best_rank} = best
          if rank < best_rank, do: {idx, rank}, else: best

        true ->
          best
      end

    do_best_merge_pair_naive(ranks, [b | rest], idx + 1, best)
  end

  defp merge_at_naive(parts, idx) when is_integer(idx) and idx >= 0 do
    {left, rest} = Enum.split(parts, idx)

    case rest do
      [a, b | tail] -> left ++ [a <> b] ++ tail
      _ -> parts
    end
  end

  defp merge_parts_heap(ranks, bytes) when is_map(ranks) and is_binary(bytes) do
    n = byte_size(bytes)

    tokens =
      bytes
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Map.new(fn {b, idx} -> {idx, <<b>>} end)

    next =
      if n <= 1 do
        %{}
      else
        Enum.reduce(0..(n - 1), %{}, fn idx, acc ->
          Map.put(acc, idx, if(idx == n - 1, do: nil, else: idx + 1))
        end)
      end

    prev =
      if n <= 1 do
        %{}
      else
        Enum.reduce(0..(n - 1), %{}, fn idx, acc ->
          Map.put(acc, idx, if(idx == 0, do: nil, else: idx - 1))
        end)
      end

    versions =
      if n <= 1 do
        %{0 => 0}
      else
        Enum.reduce(0..(n - 1), %{}, fn idx, acc -> Map.put(acc, idx, 0) end)
      end

    {heap, seq} = init_pair_heap(ranks, tokens, versions, n)

    {tokens, next, _prev, _versions, _heap, _seq} =
      merge_loop(ranks, tokens, next, prev, versions, heap, seq)

    collect_tokens(tokens, next, 0, [])
  end

  defp init_pair_heap(_ranks, _tokens, _versions, n) when n <= 1 do
    {:gb_sets.empty(), 0}
  end

  defp init_pair_heap(ranks, tokens, versions, n) do
    Enum.reduce(0..(n - 2), {:gb_sets.empty(), 0}, fn left, {heap, seq} ->
      right = left + 1

      case Map.get(ranks, Map.fetch!(tokens, left) <> Map.fetch!(tokens, right)) do
        rank when is_integer(rank) ->
          entry =
            {rank, left, seq, right, Map.fetch!(versions, left), Map.fetch!(versions, right)}

          {:gb_sets.add(entry, heap), seq + 1}

        _ ->
          {heap, seq}
      end
    end)
  end

  defp merge_loop(ranks, tokens, next, prev, versions, heap, seq) do
    case :gb_sets.is_empty(heap) do
      true ->
        {tokens, next, prev, versions, heap, seq}

      false ->
        {{rank, left, _stamp, right, left_ver, right_ver}, heap} = :gb_sets.take_smallest(heap)

        cond do
          Map.get(next, left) != right ->
            merge_loop(ranks, tokens, next, prev, versions, heap, seq)

          Map.get(versions, left) != left_ver ->
            merge_loop(ranks, tokens, next, prev, versions, heap, seq)

          Map.get(versions, right) != right_ver ->
            merge_loop(ranks, tokens, next, prev, versions, heap, seq)

          not Map.has_key?(tokens, left) ->
            merge_loop(ranks, tokens, next, prev, versions, heap, seq)

          not Map.has_key?(tokens, right) ->
            merge_loop(ranks, tokens, next, prev, versions, heap, seq)

          true ->
            merged = Map.fetch!(tokens, left) <> Map.fetch!(tokens, right)

            # The pair rank is implied by the merged token existing in `mergeable_ranks`.
            # We keep this check defensive to avoid surprising crashes on malformed models.
            if not is_integer(rank) or Map.get(ranks, merged) != rank do
              merge_loop(ranks, tokens, next, prev, versions, heap, seq)
            else
              next_right = Map.get(next, right)
              prev_left = Map.get(prev, left)

              tokens =
                tokens
                |> Map.put(left, merged)
                |> Map.delete(right)

              versions =
                versions
                |> Map.put(left, left_ver + 1)
                |> Map.delete(right)

              next =
                next
                |> Map.put(left, next_right)
                |> Map.delete(right)

              prev =
                prev
                |> Map.delete(right)
                |> maybe_put_prev(next_right, left)

              {heap, seq} =
                if is_integer(prev_left) do
                  push_pair(heap, seq, ranks, tokens, versions, prev_left, left)
                else
                  {heap, seq}
                end

              {heap, seq} =
                if is_integer(next_right) do
                  push_pair(heap, seq, ranks, tokens, versions, left, next_right)
                else
                  {heap, seq}
                end

              merge_loop(ranks, tokens, next, prev, versions, heap, seq)
            end
        end
    end
  end

  defp maybe_put_prev(prev, nil, _left), do: prev

  defp maybe_put_prev(prev, next_right, left) when is_integer(next_right),
    do: Map.put(prev, next_right, left)

  defp push_pair(heap, seq, ranks, tokens, versions, left, right)
       when is_integer(left) and is_integer(right) do
    with {:ok, left_bytes} <- Map.fetch(tokens, left),
         {:ok, right_bytes} <- Map.fetch(tokens, right),
         rank when is_integer(rank) <- Map.get(ranks, left_bytes <> right_bytes),
         {:ok, left_ver} <- Map.fetch(versions, left),
         {:ok, right_ver} <- Map.fetch(versions, right) do
      entry = {rank, left, seq, right, left_ver, right_ver}
      {:gb_sets.add(entry, heap), seq + 1}
    else
      _ -> {heap, seq}
    end
  end

  defp collect_tokens(tokens, next, idx, acc) when is_integer(idx) do
    token = Map.fetch!(tokens, idx)

    case Map.get(next, idx) do
      nil -> Enum.reverse([token | acc])
      next_idx when is_integer(next_idx) -> collect_tokens(tokens, next, next_idx, [token | acc])
    end
  end

  # Construction helpers

  defp compile_pat(pat_str) do
    {:ok, Regex.compile!(pat_str, "u")}
  rescue
    e in [ArgumentError, Regex.CompileError] -> {:error, {:invalid_pat_str, Exception.message(e)}}
  end

  defp compile_special_regex(special_tokens) when map_size(special_tokens) == 0 do
    {:ok, nil}
  end

  defp compile_special_regex(special_tokens) do
    tokens =
      special_tokens
      |> Map.keys()
      |> Enum.sort_by(fn token -> {-byte_size(token), token} end)

    escaped = Enum.map(tokens, &Regex.escape/1)

    {:ok, Regex.compile!("(" <> Enum.join(escaped, "|") <> ")", "u")}
  rescue
    e in [ArgumentError, Regex.CompileError] ->
      {:error, {:invalid_special_regex, Exception.message(e)}}
  end

  defp validate_mergeable_ranks(ranks) when is_map(ranks) do
    if Enum.all?(ranks, fn
         {bytes, id} when is_binary(bytes) and is_integer(id) and id >= 0 -> true
         _ -> false
       end) do
      :ok
    else
      {:error, :invalid_mergeable_ranks}
    end
  end

  defp validate_mergeable_ranks(_), do: {:error, :invalid_mergeable_ranks}

  defp validate_special_tokens(tokens) when is_map(tokens) do
    if Enum.all?(tokens, fn
         {token, id} when is_binary(token) and is_integer(id) and id >= 0 -> true
         _ -> false
       end) do
      :ok
    else
      {:error, :invalid_special_tokens}
    end
  end

  defp validate_special_tokens(_), do: {:error, :invalid_special_tokens}

  defp invert_bytes_map(ranks) when is_map(ranks) do
    decoder =
      ranks
      |> Enum.map(fn {bytes, id} -> {id, bytes} end)
      |> Map.new()

    {:ok, decoder}
  rescue
    e in ArgumentError -> {:error, {:invalid_decoder, Exception.message(e)}}
  end

  defp invert_special_tokens(tokens) when is_map(tokens) do
    by_id =
      tokens
      |> Enum.map(fn {token, id} -> {id, token} end)
      |> Map.new()

    {:ok, by_id}
  rescue
    e in ArgumentError -> {:error, {:invalid_special_tokens, Exception.message(e)}}
  end
end
