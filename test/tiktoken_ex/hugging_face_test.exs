defmodule TiktokenEx.HuggingFaceTest do
  use ExUnit.Case, async: true

  alias TiktokenEx.HuggingFace

  test "resolve_file caches downloads in the local cache" do
    with_tmp_dir(fn dir ->
      pid = self()

      fetcher = fn repo_id, revision, filename, _opts ->
        send(pid, {:fetch, repo_id, revision, filename})
        {:ok, "payload"}
      end

      opts = [cache_dir: dir, fetch_fun: fetcher]

      assert {:ok, path1} =
               HuggingFace.resolve_file("org/repo", "main", "file.txt", opts)

      assert File.read!(path1) == "payload"
      assert_receive {:fetch, "org/repo", "main", "file.txt"}

      fetcher2 = fn _repo_id, _revision, _filename, _opts ->
        send(pid, :unexpected_fetch)
        {:ok, "other"}
      end

      assert {:ok, path2} =
               HuggingFace.resolve_file("org/repo", "main", "file.txt",
                 cache_dir: dir,
                 fetch_fun: fetcher2
               )

      assert path1 == path2
      assert File.read!(path2) == "payload"
      refute_receive :unexpected_fetch, 50
    end)
  end

  test "resolve_file sanitizes repo_id to avoid traversal" do
    with_tmp_dir(fn dir ->
      fetcher = fn _repo_id, _revision, _filename, _opts -> {:ok, "payload"} end

      {:ok, path} =
        HuggingFace.resolve_file("../evil/repo", "main", "file.txt",
          cache_dir: dir,
          fetch_fun: fetcher
        )

      expanded_root = Path.expand(Path.join(dir, "hf"))
      expanded_path = Path.expand(path)

      assert String.starts_with?(expanded_path, expanded_root)

      repo_segment =
        path
        |> Path.split()
        |> Enum.at(-3)

      refute String.contains?(repo_segment, "..")
      refute String.contains?(repo_segment, "/")
    end)
  end

  test "resolve_file is safe under concurrent calls" do
    with_tmp_dir(fn dir ->
      fetcher = fn _repo_id, _revision, _filename, _opts ->
        Process.sleep(10)
        {:ok, String.duplicate("x", 1024)}
      end

      opts = [cache_dir: dir, fetch_fun: fetcher]

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            HuggingFace.resolve_file("org/repo", "main", "file.txt", opts)
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 1000))
      assert Enum.all?(results, fn {:ok, path} -> File.exists?(path) end)

      {:ok, path} = hd(results)
      assert File.read!(path) == String.duplicate("x", 1024)
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
