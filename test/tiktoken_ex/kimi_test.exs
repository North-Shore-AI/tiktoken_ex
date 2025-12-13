defmodule TiktokenEx.KimiTest do
  use ExUnit.Case, async: true

  alias TiktokenEx.Kimi

  test "upstream pat_str contains intersections and the translated pat_str compiles" do
    assert String.contains?(Kimi.upstream_pat_str(), "&&")
    refute String.contains?(Kimi.pat_str(), "&&")

    assert {:ok, re} = Regex.compile(Kimi.pat_str(), "u")
    assert [["Say"], [" hi"]] == Regex.scan(re, "Say hi")
  end

  test "from_hf_files returns errors for invalid HuggingFace tokenizer files" do
    with_tmp_dir(fn dir ->
      model_path = Path.join(dir, "tiktoken.model")
      config_path = Path.join(dir, "tokenizer_config.json")

      File.write!(model_path, "\n")
      File.write!(config_path, "{}")

      assert {:error, {:empty_tiktoken_model, ^model_path}} =
               Kimi.from_hf_files(
                 tiktoken_model_path: model_path,
                 tokenizer_config_path: config_path
               )
    end)

    with_tmp_dir(fn dir ->
      model_path = Path.join(dir, "tiktoken.model")
      config_path = Path.join(dir, "tokenizer_config.json")

      File.write!(model_path, "not_base64 0\n")
      File.write!(config_path, "{}")

      assert {:error, {:invalid_tiktoken_model, ^model_path, _}} =
               Kimi.from_hf_files(
                 tiktoken_model_path: model_path,
                 tokenizer_config_path: config_path
               )
    end)

    with_tmp_dir(fn dir ->
      model_path = Path.join(dir, "tiktoken.model")
      config_path = Path.join(dir, "tokenizer_config.json")

      File.write!(model_path, "YQ== not_an_int\n")
      File.write!(config_path, "{}")

      assert {:error, {:invalid_tiktoken_model, ^model_path, _}} =
               Kimi.from_hf_files(
                 tiktoken_model_path: model_path,
                 tokenizer_config_path: config_path
               )
    end)

    with_tmp_dir(fn dir ->
      model_path = Path.join(dir, "tiktoken.model")
      config_path = Path.join(dir, "tokenizer_config.json")

      File.write!(model_path, "YQ== 0\n")
      File.write!(config_path, "{")

      assert {:error, {:invalid_json, ^config_path, _}} =
               Kimi.from_hf_files(
                 tiktoken_model_path: model_path,
                 tokenizer_config_path: config_path
               )
    end)

    with_tmp_dir(fn dir ->
      model_path = Path.join(dir, "tiktoken.model")
      config_path = Path.join(dir, "tokenizer_config.json")

      File.write!(model_path, "YQ== 0\n")
      File.write!(config_path, ~s({"added_tokens_decoder":{"abc":{"content":"[BOS]"}}}))

      assert {:error, {:invalid_special_tokens, _}} =
               Kimi.from_hf_files(
                 tiktoken_model_path: model_path,
                 tokenizer_config_path: config_path
               )
    end)
  end

  test "from_hf_files forwards special_token_matching to Encoding.new" do
    with_tmp_dir(fn dir ->
      model_path = Path.join(dir, "tiktoken.model")
      config_path = Path.join(dir, "tokenizer_config.json")

      File.write!(model_path, "YQ== 0\n")
      File.write!(config_path, "{}")

      assert {:ok, enc} =
               Kimi.from_hf_files(
                 tiktoken_model_path: model_path,
                 tokenizer_config_path: config_path,
                 special_token_matching: :longest
               )

      assert enc.special_token_matching == :longest
    end)
  end

  defp with_tmp_dir(fun) when is_function(fun, 1) do
    dir = Path.join(System.tmp_dir!(), "tiktoken_ex_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      _ = File.rm_rf(dir)
    end
  end
end
