defmodule TiktokenEx.KimiHfRepoTest do
  use ExUnit.Case, async: false

  alias TiktokenEx.{Cache, Encoding, Kimi}

  setup do
    Cache.clear()
    :ok
  end

  test "from_hf_repo resolves files and builds an encoding" do
    with_tmp_dir(fn dir ->
      pid = self()

      fetcher = fn repo_id, revision, filename, _opts ->
        send(pid, {:fetch, repo_id, revision, filename})

        case filename do
          "tiktoken.model" -> {:ok, "YQ== 0\n"}
          "tokenizer_config.json" -> {:ok, "{}"}
          _ -> {:error, {:unexpected_filename, filename}}
        end
      end

      assert {:ok, enc} =
               Kimi.from_hf_repo("org/repo",
                 revision: "main",
                 cache_dir: dir,
                 fetch_fun: fetcher
               )

      assert_receive {:fetch, "org/repo", "main", "tiktoken.model"}
      assert_receive {:fetch, "org/repo", "main", "tokenizer_config.json"}

      assert {:ok, [0]} == Encoding.encode(enc, "a")
    end)
  end

  test "from_hf_repo can reuse the ETS encoding cache" do
    with_tmp_dir(fn dir ->
      fetcher = fn _repo_id, _revision, filename, _opts ->
        case filename do
          "tiktoken.model" -> {:ok, "YQ== 0\n"}
          "tokenizer_config.json" -> {:ok, "{}"}
          _ -> {:error, :unexpected}
        end
      end

      assert {:ok, enc1} =
               Kimi.from_hf_repo("org/repo",
                 revision: "main",
                 cache_dir: dir,
                 fetch_fun: fetcher,
                 encoding_cache: true
               )

      with_tmp_dir(fn empty_dir ->
        pid = self()

        fetcher2 = fn _repo_id, _revision, _filename, _opts ->
          send(pid, :unexpected_fetch)
          {:error, :should_not_fetch}
        end

        assert {:ok, enc2} =
                 Kimi.from_hf_repo("org/repo",
                   revision: "main",
                   cache_dir: empty_dir,
                   fetch_fun: fetcher2,
                   encoding_cache: true
                 )

        assert enc1 == enc2
        refute_receive :unexpected_fetch, 50
      end)
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
