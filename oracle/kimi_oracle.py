#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any

import requests
import tiktoken
import base64


DEFAULT_REPO_ID = "moonshotai/Kimi-K2-Thinking"
DEFAULT_REVISION = "612681931a8c906ddb349f8ad0f582cb552189cd"
HF_BASE_URL = "https://huggingface.co"
NUM_RESERVED_SPECIAL_TOKENS = 256


def kimi_pat_str() -> str:
    # Copied from `tokenization_kimi.py` in the Kimi repo.
    parts = [
        r"""[\p{Han}]+""",
        r"""[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?""",
        r"""[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]+[\p{Ll}\p{Lm}\p{Lo}\p{M}&&[^\p{Han}]]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?""",
        r"""\p{N}{1,3}""",
        r""" ?[^\s\p{L}\p{N}]+[\r\n]*""",
        r"""\s*[\r\n]+""",
        r"""\s+(?!\S)""",
        r"""\s+""",
    ]
    return "|".join(parts)


def hf_resolve(repo_id: str, revision: str, filename: str) -> str:
    return f"{HF_BASE_URL}/{repo_id}/resolve/{revision}/{filename}"


def download_if_missing(path: pathlib.Path, url: str) -> pathlib.Path:
    if path.exists():
        return path

    path.parent.mkdir(parents=True, exist_ok=True)
    resp = requests.get(url, timeout=120)
    resp.raise_for_status()
    path.write_bytes(resp.content)
    return path


def load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def build_special_tokens(tokenizer_config: dict[str, Any], num_base_tokens: int) -> dict[str, int]:
    added = tokenizer_config.get("added_tokens_decoder", {}) or {}
    mapping: dict[int, str] = {}

    for key, attrs in added.items():
        try:
            token_id = int(key)
        except Exception:
            continue
        if isinstance(attrs, dict) and isinstance(attrs.get("content"), str):
            mapping[token_id] = attrs["content"]

    special_tokens: dict[str, int] = {}
    for token_id in range(num_base_tokens, num_base_tokens + NUM_RESERVED_SPECIAL_TOKENS):
        tok = mapping.get(token_id, f"<|reserved_token_{token_id}|>")
        special_tokens[tok] = token_id

    return special_tokens


def build_encoding(model_path: pathlib.Path, config_path: pathlib.Path) -> tiktoken.Encoding:
    ranks: dict[bytes, int] = {}
    for line in model_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        b64, rank_str = line.split(maxsplit=1)
        ranks[base64.b64decode(b64)] = int(rank_str)

    config = load_json(config_path)
    special_tokens = build_special_tokens(config, len(ranks))

    return tiktoken.Encoding(
        name="kimi",
        pat_str=kimi_pat_str(),
        mergeable_ranks=ranks,
        special_tokens=special_tokens,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Kimi TikToken oracle (Python tiktoken).")
    parser.add_argument("--repo-id", default=DEFAULT_REPO_ID)
    parser.add_argument("--revision", default=DEFAULT_REVISION)
    parser.add_argument("--cache-dir", default=str(pathlib.Path(__file__).parent / "kimi"))
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--input-path", default=None)
    args = parser.parse_args()

    cache_dir = pathlib.Path(args.cache_dir) / args.revision
    model_path = cache_dir / "tiktoken.model"
    config_path = cache_dir / "tokenizer_config.json"

    download_if_missing(model_path, hf_resolve(args.repo_id, args.revision, "tiktoken.model"))
    download_if_missing(
        config_path, hf_resolve(args.repo_id, args.revision, "tokenizer_config.json")
    )

    if args.download_only:
        return 0

    if args.input_path:
        payload = json.loads(pathlib.Path(args.input_path).read_text(encoding="utf-8"))
    else:
        payload = json.loads(sys.stdin.read() or "{}")
    texts = payload.get("texts", [])
    allow_special_tokens = bool(payload.get("allow_special_tokens", True))

    enc = build_encoding(model_path, config_path)

    out = []
    for text in texts:
        if not isinstance(text, str):
            raise TypeError(f"expected text string, got: {type(text)}")

        if allow_special_tokens:
            ids = enc.encode(text, allowed_special="all")
        else:
            ids = enc.encode(text, disallowed_special=())

        out.append({"text": text, "ids": ids, "decoded": enc.decode(ids)})

    sys.stdout.write(
        json.dumps(
            {
                "repo_id": args.repo_id,
                "revision": args.revision,
                "allow_special_tokens": allow_special_tokens,
                "results": out,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
