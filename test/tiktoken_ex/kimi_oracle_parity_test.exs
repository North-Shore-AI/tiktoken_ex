defmodule TiktokenEx.KimiOracleParityTest do
  use ExUnit.Case, async: false

  alias TiktokenEx.{Encoding, Kimi}

  @moduletag :oracle

  @repo_id "moonshotai/Kimi-K2-Thinking"
  @revision "612681931a8c906ddb349f8ad0f582cb552189cd"

  setup_all do
    project_root = Path.expand("../..", __DIR__)
    python = Path.join([project_root, "oracle", ".venv", "bin", "python"])
    script = Path.join([project_root, "oracle", "kimi_oracle.py"])
    cache_dir = Path.join([project_root, "oracle", "kimi"])

    ensure_python_oracle!(python, script, cache_dir)

    model_path = Path.join([cache_dir, @revision, "tiktoken.model"])
    config_path = Path.join([cache_dir, @revision, "tokenizer_config.json"])

    assert File.exists?(model_path)
    assert File.exists?(config_path)

    assert {:ok, encoding} =
             Kimi.from_hf_files(
               tiktoken_model_path: model_path,
               tokenizer_config_path: config_path
             )

    {:ok, %{encoding: encoding, python: python, script: script, cache_dir: cache_dir}}
  end

  test "matches Python tiktoken oracle on a fixed corpus (allow_special_tokens: true)", ctx do
    texts = [
      "",
      "Say hi",
      "hello world",
      "  leading",
      "trailing  ",
      "multiple   spaces",
      "tabs\tand\nnewlines\r\nok",
      "1234567890",
      "你好世界",
      "Mix 汉字 and ASCII",
      "punctuation!?.,;:-()[]{}",
      "[BOS]Hello[EOS]",
      "<|im_user|>Hello<|im_end|>",
      "<|reserved_token_0|>",
      "<|reserved_token_999999|>",
      "emoji 🙂🙃",
      "combining e\u0301"
    ]

    assert_parity(ctx, texts, allow_special_tokens: true)
  end

  test "matches Python tiktoken oracle on a fixed corpus (allow_special_tokens: false)", ctx do
    texts = [
      "[BOS]Hello[EOS]",
      "<|im_user|>Hello<|im_end|>",
      "<|reserved_token_#{@revision}|>",
      "Say hi"
    ]

    assert_parity(ctx, texts, allow_special_tokens: false)
  end

  test "matches Python tiktoken oracle on special-token edge cases (allow_special_tokens: true)",
       ctx do
    specials =
      ctx.encoding.special_tokens
      |> Map.keys()
      |> Enum.sort()

    [s1, s2, s3 | _] = specials

    adjacency = s1 <> s2 <> s3 <> s1
    repetition = String.duplicate(s1, 8)

    near_miss_append = s1 <> "X"

    near_miss_truncate =
      if String.length(s1) <= 1 do
        s1
      else
        String.slice(s1, 0, String.length(s1) - 1)
      end

    all_once_adjacent = Enum.join(specials, "")
    all_once_spaced = Enum.join(specials, " ")

    texts = [
      adjacency,
      repetition,
      "prefix-" <> s1 <> "-suffix",
      near_miss_append,
      near_miss_truncate,
      all_once_adjacent,
      all_once_spaced
    ]

    assert_parity(ctx, texts, allow_special_tokens: true)
  end

  test "matches Python tiktoken oracle on special-token edge cases (allow_special_tokens: false)",
       ctx do
    specials =
      ctx.encoding.special_tokens
      |> Map.keys()
      |> Enum.sort()

    [s1, s2 | _] = specials

    texts = [
      s1 <> s2,
      "prefix-" <> s1 <> "-suffix",
      s1 <> "X",
      s2 <> "Y",
      "[BOS][EOS]<|im_end|>"
    ]

    assert_parity(ctx, texts, allow_special_tokens: false)
  end

  test "matches Python tiktoken oracle on a Unicode stress corpus", ctx do
    texts = [
      "مرحبا بالعالم",
      "שלום עולם",
      "नमस्ते दुनिया",
      "สวัสดีโลก",
      "こんにちは世界",
      "안녕하세요 세계",
      "γειά σου κόσμε",
      "Здравствуй, мир",
      "café",
      "cafe\u0301",
      "a\u0301\u0327",
      "👩‍💻",
      "👨‍👩‍👧‍👦",
      "🏳️‍🌈",
      "✌️",
      "🇺🇸",
      "𝔘𝔫𝔦𝔠𝔬𝔡𝔢",
      "𐍈",
      "𝄞music",
      "zero\u200dwidth\u200cjoiners",
      "line1\r\nline2\nline3\tend",
      "mix: عربى + English + 汉字 + 🙂"
    ]

    assert_parity(ctx, texts, allow_special_tokens: true)
  end

  test "matches Python tiktoken oracle on regex-boundary cases", ctx do
    texts = [
      "ABC汉DEF",
      "Abc汉def",
      "汉ABC",
      "ABC汉",
      "A汉a",
      "a汉A",
      "Don't stop",
      "we're testing",
      "it's fine",
      "HELLOWorld",
      "!Hello",
      "mix汉字andASCII",
      "A\u0301b"
    ]

    assert_parity(ctx, texts, allow_special_tokens: true)
  end

  test "matches Python tiktoken oracle on long inputs (regression)", ctx do
    texts = [
      String.duplicate("a", 30_000),
      String.duplicate(" ", 30_000),
      String.duplicate("ab漢", 10_000)
    ]

    assert_parity(ctx, texts, allow_special_tokens: true)
  end

  test "matches Python tiktoken oracle on a randomized corpus", ctx do
    :rand.seed(:exsss, {1, 2, 3})

    graphemes =
      String.graphemes(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \t\n" <>
          ".,;:!?-_/\\'\"()[]{}" <>
          "你好世界🙂🙃" <>
          "<|im_end|>[BOS][EOS]"
      )

    texts =
      for _ <- 1..1_000 do
        len = :rand.uniform(257) - 1

        if len == 0 do
          ""
        else
          Enum.map_join(1..len, fn _ ->
            Enum.at(graphemes, :rand.uniform(length(graphemes)) - 1)
          end)
        end
      end

    assert_parity(ctx, texts, allow_special_tokens: true)
  end

  defp assert_parity(ctx, texts, allow_special_tokens: allow_special_tokens) do
    oracle = python_oracle(ctx.python, ctx.script, ctx.cache_dir, allow_special_tokens, texts)

    results = oracle["results"]
    assert length(results) == length(texts)

    Enum.zip(texts, results)
    |> Enum.each(fn
      {text, %{"text" => oracle_text, "ids" => expected_ids, "decoded" => expected_decoded}} ->
        assert oracle_text == text

        assert {:ok, expected_ids} ==
                 Encoding.encode(ctx.encoding, text, allow_special_tokens: allow_special_tokens)

        assert {:ok, expected_decoded} == Encoding.decode(ctx.encoding, expected_ids)
    end)
  end

  defp python_oracle(python, script, cache_dir, allow_special_tokens, texts) do
    payload = Jason.encode!(%{texts: texts, allow_special_tokens: allow_special_tokens})

    args = [
      script,
      "--repo-id",
      @repo_id,
      "--revision",
      @revision,
      "--cache-dir",
      cache_dir
    ]

    tmp_dir = Path.join(System.tmp_dir!(), "tiktoken_ex_oracle")
    File.mkdir_p!(tmp_dir)
    input_path = Path.join(tmp_dir, "input_#{System.unique_integer([:positive])}.json")
    File.write!(input_path, payload)

    args = args ++ ["--input-path", input_path]

    try do
      case System.cmd(python, args, stderr_to_stdout: true) do
        {out, 0} ->
          Jason.decode!(out)

        {out, status} ->
          raise "python oracle failed (#{status}):\n#{out}"
      end
    after
      _ = File.rm(input_path)
    end
  end

  defp ensure_python_oracle!(python, script, cache_dir) do
    cond do
      not File.exists?(python) ->
        raise "python venv not found at #{python}; create it with: python3 -m venv oracle/.venv && oracle/.venv/bin/pip install tiktoken"

      not File.exists?(script) ->
        raise "python oracle script missing: #{script}"

      true ->
        args = [
          script,
          "--repo-id",
          @repo_id,
          "--revision",
          @revision,
          "--cache-dir",
          cache_dir,
          "--download-only"
        ]

        case System.cmd(python, args, stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, status} -> raise "python oracle download failed (#{status}):\n#{out}"
        end
    end
  end
end
