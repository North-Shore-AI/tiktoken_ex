defmodule TiktokenEx.Kimi do
  @moduledoc """
  Helpers for Kimi K2 TikToken tokenizers.

  Kimi tokenizers ship a `tiktoken.model` file (mergeable ranks) and a
  TikToken-compatible `pat_str` that uses character class intersections (`&&`)
  not supported by PCRE (and therefore Elixir's Regex engine).

  This module provides a PCRE-compatible `pat_str` plus helpers to build a
  `TiktokenEx.Encoding` from HuggingFace-style tokenizer configs.
  """

  alias TiktokenEx.{Cache, Encoding, HuggingFace}

  @num_reserved_special_tokens 256

  @doc """
  Kimi's upstream `pat_str` as authored in `tokenization_kimi.py`.
  """
  @spec upstream_pat_str() :: String.t()
  def upstream_pat_str do
    [
      ~S/[\p{Han}]+/,
      ~S/[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?/,
      ~S/[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?/,
      ~S/\p{N}{1,3}/,
      ~S/ ?[^\s\p{L}\p{N}]+[\r\n]*/,
      ~S/\s*[\r\n]+/,
      ~S/\s+(?!\S)/,
      ~S/\s+/
    ]
    |> Enum.join("|")
  end

  @doc """
  PCRE-compatible variant of Kimi's `pat_str`.

  Elixir uses Erlang's PCRE engine, which does not support `&&` intersections in
  character classes. We translate:

      [<CLASS>&&[^\\p{Han}]]

  into a per-codepoint negative lookahead:

      (?:(?!\\p{Han})<CLASS>)
  """
  @spec pat_str() :: String.t()
  def pat_str do
    upstream_pat_str()
    |> translate_intersection_classes()
  end

  @doc """
  Load a Kimi-compatible encoding from a HuggingFace repo.

  ## Options

    * `:revision` - Git revision or tag (default: `"main"`).
    * `:cache_dir` - Override the HuggingFace cache root.
    * `:fetch_fun` - Custom fetcher `fun.(repo_id, revision, filename, opts)`.
    * `:http_timeout_ms` - Timeout for the default HTTP fetcher.
    * `:encoding_cache` - When true, reuse an ETS cache keyed by repo + revision.
    * `:pat_str` - Override the pattern used for splitting.
    * `:special_token_matching` - Pass-through to `TiktokenEx.Encoding.new/1`.
  """
  @spec from_hf_repo(String.t(), keyword()) :: {:ok, Encoding.t()} | {:error, term()}
  def from_hf_repo(repo_id, opts \\ []) when is_binary(repo_id) and is_list(opts) do
    revision = Keyword.get(opts, :revision, "main")
    pat_str = Keyword.get(opts, :pat_str, pat_str())
    special_token_matching = Keyword.get(opts, :special_token_matching, :parity)
    use_encoding_cache = Keyword.get(opts, :encoding_cache, false)

    hf_opts = Keyword.take(opts, [:cache_dir, :fetch_fun, :http_timeout_ms])

    loader = fn ->
      with {:ok, model_path} <-
             HuggingFace.resolve_file(repo_id, revision, "tiktoken.model", hf_opts),
           {:ok, config_path} <-
             HuggingFace.resolve_file(repo_id, revision, "tokenizer_config.json", hf_opts) do
        from_hf_files(
          tiktoken_model_path: model_path,
          tokenizer_config_path: config_path,
          pat_str: pat_str,
          special_token_matching: special_token_matching
        )
      end
    end

    if use_encoding_cache do
      Cache.get_or_load({repo_id, revision, pat_str, special_token_matching}, loader)
    else
      loader.()
    end
  end

  @doc """
  Load a Kimi-compatible encoding from local HuggingFace files.

  ## Options

    * `:pat_str` - Override the pattern used for splitting.
    * `:special_token_matching` - Pass-through to `TiktokenEx.Encoding.new/1`.
  """
  @spec from_hf_files(keyword()) :: {:ok, Encoding.t()} | {:error, term()}
  def from_hf_files(opts) when is_list(opts) do
    model_path = Keyword.fetch!(opts, :tiktoken_model_path)
    config_path = Keyword.fetch!(opts, :tokenizer_config_path)
    pat_str = Keyword.get(opts, :pat_str, pat_str())
    special_token_matching = Keyword.get(opts, :special_token_matching, :parity)

    with {:ok, mergeable_ranks} <- load_tiktoken_model(model_path),
         {:ok, config} <- load_json(config_path),
         {:ok, special_tokens} <- build_special_tokens(config, map_size(mergeable_ranks)) do
      Encoding.new(
        pat_str: pat_str,
        mergeable_ranks: mergeable_ranks,
        special_tokens: special_tokens,
        special_token_matching: special_token_matching
      )
    end
  end

  @doc false
  def load_tiktoken_model(path) when is_binary(path) do
    mergeable_ranks =
      path
      |> File.stream!(:line, [])
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(String.trim(line), ~r/\s+/, parts: 2) do
          [b64, rank_str] ->
            bytes = Base.decode64!(b64)
            rank = String.to_integer(rank_str)
            Map.put(acc, bytes, rank)

          _ ->
            acc
        end
      end)

    if map_size(mergeable_ranks) == 0 do
      {:error, {:empty_tiktoken_model, path}}
    else
      {:ok, mergeable_ranks}
    end
  rescue
    e -> {:error, {:invalid_tiktoken_model, path, Exception.message(e)}}
  end

  defp load_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, json} <- Jason.decode(contents) do
      {:ok, json}
    else
      {:error, reason} -> {:error, {:invalid_json, path, reason}}
    end
  end

  defp build_special_tokens(config, num_base_tokens) when is_map(config) do
    added =
      config
      |> Map.get("added_tokens_decoder", %{})
      |> Enum.reduce(%{}, fn {id, attrs}, acc ->
        id = if is_integer(id), do: id, else: String.to_integer(id)
        content = attrs["content"] || attrs[:content]
        if is_binary(content), do: Map.put(acc, id, content), else: acc
      end)

    tokens =
      Enum.reduce(
        num_base_tokens..(num_base_tokens + @num_reserved_special_tokens - 1),
        %{},
        fn id, acc ->
          token = Map.get(added, id, "<|reserved_token_#{id}|>")
          Map.put(acc, token, id)
        end
      )

    {:ok, tokens}
  rescue
    e -> {:error, {:invalid_special_tokens, Exception.message(e)}}
  end

  defp translate_intersection_classes(pat_str) do
    pat_str
    |> String.replace(
      ~S|[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*|,
      ~S|(?:(?!\p{Han})[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}])*|
    )
    |> String.replace(
      ~S|[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+|,
      ~S|(?:(?!\p{Han})[\p{Ll}\p{Lm}\p{Lo}\p{M}])+|
    )
    |> String.replace(
      ~S|[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+|,
      ~S|(?:(?!\p{Han})[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}])+|
    )
    |> String.replace(
      ~S|[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*|,
      ~S|(?:(?!\p{Han})[\p{Ll}\p{Lm}\p{Lo}\p{M}])*|
    )
  end
end
