defmodule TiktokenEx.HuggingFace do
  @moduledoc """
  Resolve HuggingFace files with a local cache and injectable fetchers.

  The default fetcher uses `:httpc` and writes to the user cache directory.
  """

  @base_url "https://huggingface.co"

  @spec resolve_file(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_file(repo_id, revision, filename, opts \\ [])
      when is_binary(repo_id) and is_binary(revision) and is_binary(filename) and is_list(opts) do
    cache_root = Keyword.get(opts, :cache_dir, default_cache_dir())
    repo_segment = sanitize_repo_id(repo_id)
    path = Path.join([cache_root, "hf", repo_segment, revision, filename])

    if File.exists?(path) do
      {:ok, path}
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, body} <- fetch_file(repo_id, revision, filename, opts),
           :ok <- write_atomic(path, body) do
        {:ok, path}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_file(repo_id, revision, filename, opts) do
    case Keyword.get(opts, :fetch_fun) do
      fun when is_function(fun, 4) ->
        fun.(repo_id, revision, filename, opts)

      nil ->
        fetch_httpc(repo_id, revision, filename, opts)

      other ->
        {:error, {:invalid_fetch_fun, other}}
    end
  end

  defp fetch_httpc(repo_id, revision, filename, opts) do
    url = "#{@base_url}/#{repo_id}/resolve/#{revision}/#{filename}"
    timeout_ms = Keyword.get(opts, :http_timeout_ms, 120_000)
    headers = [{~c"user-agent", ~c"tiktoken_ex"}]

    with :ok <- ensure_httpc_started() do
      ssl_options =
        [
          verify: :verify_peer,
          cacerts: public_key_cacerts(),
          depth: 3
        ]
        |> maybe_add_hostname_check()

      http_options = [
        timeout: timeout_ms,
        connect_timeout: timeout_ms,
        autoredirect: true,
        ssl: ssl_options
      ]

      options = [body_format: :binary, full_result: true]

      case :httpc.request(:get, {String.to_charlist(url), headers}, http_options, options) do
        {:ok, {{_, status, _}, _resp_headers, body}}
        when is_integer(status) and status >= 200 and status < 300 ->
          {:ok, body}

        {:ok, {{_, 404, _}, _resp_headers, _body}} ->
          {:error, {:not_found, repo_id, revision, filename}}

        {:ok, {{_, status, _}, _resp_headers, body}} ->
          {:error, {:http_status, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp ensure_httpc_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:public_key),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    else
      {:error, reason} -> {:error, {:httpc_start_failed, reason}}
    end
  end

  defp default_cache_dir do
    :filename.basedir(:user_cache, "tiktoken_ex")
  end

  defp sanitize_repo_id(repo_id) do
    repo_id
    |> String.replace("/", "__")
    |> String.replace("..", "_")
  end

  defp write_atomic(path, body) when is_binary(path) and is_binary(body) do
    dir = Path.dirname(path)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.write(tmp_path, body),
         :ok <- finalize_atomic_write(tmp_path, path) do
      :ok
    else
      {:error, reason} -> {:error, {:cache_write_failed, path, reason}}
    end
  end

  defp finalize_atomic_write(tmp_path, path) do
    case File.rename(tmp_path, path) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp_path)

        if File.exists?(path) do
          :ok
        else
          {:error, reason}
        end
    end
  end

  defp public_key_cacerts do
    if Code.ensure_loaded?(:public_key) and function_exported?(:public_key, :cacerts_get, 0) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(:public_key, :cacerts_get, [])
    else
      []
    end
  end

  defp maybe_add_hostname_check(ssl_options) do
    case public_key_hostname_match_fun() do
      nil -> ssl_options
      match_fun -> Keyword.put(ssl_options, :customize_hostname_check, match_fun: match_fun)
    end
  end

  defp public_key_hostname_match_fun do
    if Code.ensure_loaded?(:public_key) and
         function_exported?(:public_key, :pkix_verify_hostname_match_fun, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(:public_key, :pkix_verify_hostname_match_fun, [:https])
    else
      nil
    end
  end
end
