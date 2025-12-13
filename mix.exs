defmodule TiktokenEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/North-Shore-AI/tiktoken_ex"
  @docs_url "https://hexdocs.pm/tiktoken_ex"

  def version, do: @version

  def project do
    [
      app: :tiktoken_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package(),
      name: "TiktokenEx",
      source_url: @source_url,
      homepage_url: @source_url,
      preferred_cli_env: [
        dialyzer: :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp description do
    """
    Pure-Elixir TikToken-style byte-level BPE tokenizer, with helpers for Kimi K2 encodings.
    """
  end

  defp docs do
    [
      main: "overview",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @docs_url,
      assets: %{"assets" => "assets"},
      logo: "assets/tiktoken_ex.svg",
      extras: [
        {"README.md", [filename: "overview", title: "Overview"]},
        {"LICENSE", [filename: "license", title: "License"]}
      ]
    ]
  end

  defp package do
    [
      name: "tiktoken_ex",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => @docs_url
      },
      files: ~w(lib mix.exs README.md LICENSE assets)
    ]
  end
end
