defmodule TiktokenEx.Cache do
  @moduledoc """
  Optional ETS cache for encodings keyed by repo and revision.

  This cache is opt-in and safe to ignore in most usage.
  """

  @table __MODULE__

  @spec get_or_load(term(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def get_or_load(key, loader) when is_function(loader, 0) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        {:ok, value}

      [] ->
        case loader.() do
          {:ok, value} ->
            true = :ets.insert(@table, {key, value})
            {:ok, value}

          other ->
            other
        end
    end
  end

  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      tid ->
        :ets.delete_all_objects(tid)
        :ok
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
