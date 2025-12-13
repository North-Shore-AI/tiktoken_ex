<div align="center">
  <img src="assets/tiktoken_ex.svg" width="400" alt="TiktokenEx Logo" />
</div>

# TiktokenEx

**Pure Elixir TikToken-style byte-level BPE tokenizer (Kimi K2 compatible).**

[![CI](https://github.com/North-Shore-AI/tiktoken_ex/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/North-Shore-AI/tiktoken_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/tiktoken_ex.svg)](https://hex.pm/packages/tiktoken_ex)
[![Docs](https://img.shields.io/badge/docs-hexdocs.pm-blue.svg)](https://hexdocs.pm/tiktoken_ex)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

TiktokenEx is a small, dependency-light implementation of the core TikToken
idea:

- Split text with a Unicode-aware regex (`pat_str`)
- Encode pieces with byte-pair encoding (BPE) using `mergeable_ranks`
- Optionally recognize special tokens (e.g. `<|im_end|>`)

It’s focused on matching the behavior of MoonshotAI’s **Kimi K2** tokenizers
that ship a `tiktoken.model` file and a TikToken-compatible `pat_str`.

## Installation

Add `tiktoken_ex` to your dependencies:

```elixir
def deps do
  [
    {:tiktoken_ex, "~> 0.1.0"}
  ]
end
```

## Usage

### Build an encoding directly

```elixir
alias TiktokenEx.Encoding

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

{:ok, ids} = Encoding.encode(enc, "Hello")
{:ok, text} = Encoding.decode(enc, ids)
```

### Load a Kimi K2 encoding from local HuggingFace artifacts

Kimi provides:

- `tiktoken.model` (mergeable ranks)
- `tokenizer_config.json` (special tokens, etc)

```elixir
alias TiktokenEx.{Encoding, Kimi}

{:ok, enc} =
  Kimi.from_hf_files(
    tiktoken_model_path: "/path/to/tiktoken.model",
    tokenizer_config_path: "/path/to/tokenizer_config.json"
  )

{:ok, ids} = Encoding.encode(enc, "Say hi")
{:ok, decoded} = Encoding.decode(enc, ids)
```

### Special tokens

Special tokens are recognized by default. To treat them as plain text:

```elixir
{:ok, ids} = TiktokenEx.Encoding.encode(enc, "<|im_end|>", allow_special_tokens: false)
```

### Regex compatibility note

Kimi’s upstream `pat_str` uses character-class intersections (`&&`), which are
not supported by Erlang’s PCRE engine. `TiktokenEx.Kimi.pat_str/0` provides a
PCRE-compatible translation.

## Development

- Run tests: `mix test`
- Run oracle parity tests (downloads HF artifacts): `mix test --include oracle`
- Run dialyzer: `mix dialyzer`

## License

MIT © 2025 North-Shore-AI
