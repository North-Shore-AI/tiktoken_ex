#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ORACLE=0
ONLY_BACKEND=""
REQUIRE_RUST=0
NO_COLOR=0
MIX_ARGS=()

usage() {
  cat <<'EOF'
TiktokenEx • Backend Test Runner

Usage:
  scripts/test_backends.sh [options] [-- <mix test args...>]

Options:
  --oracle           Include oracle parity tests (tag :oracle)
  --only BACKEND     Run only one backend: elixir | rust
  --require-rust     Fail if Rust backend isn't available
  --no-color         Disable ANSI colors
  -h, --help         Show this help

Examples:
  scripts/test_backends.sh
  scripts/test_backends.sh --oracle
  scripts/test_backends.sh --require-rust --oracle
  scripts/test_backends.sh --only elixir -- --seed 0
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oracle)
      ORACLE=1
      shift
      ;;
    --only)
      ONLY_BACKEND="${2:-}"
      shift 2
      ;;
    --require-rust)
      REQUIRE_RUST=1
      shift
      ;;
    --no-color)
      NO_COLOR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      MIX_ARGS+=("$@")
      break
      ;;
    *)
      MIX_ARGS+=("$1")
      shift
      ;;
  esac
done

color_enabled() {
  [[ $NO_COLOR -eq 0 ]] && [[ -t 1 ]] && [[ -z "${NO_COLOR+x}" ]]
}

if color_enabled; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_PURPLE=$'\033[35m'
  C_ORANGE=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_PURPLE=""
  C_ORANGE=""
  C_GREEN=""
  C_RED=""
  C_CYAN=""
fi

say() { printf '%s\n' "$*"; }
rule() { say "${C_DIM}------------------------------------------------------------${C_RESET}"; }
ok() { say "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { say "${C_ORANGE}[SKIP]${C_RESET} $*"; }
fail() { say "${C_RED}[FAIL]${C_RESET} $*"; }
info() { say "${C_CYAN}[INFO]${C_RESET} $*"; }

banner() {
  rule
  say "${C_PURPLE}${C_BOLD}   TiktokenEx${C_RESET}${C_DIM}  (Kimi K2 compatible)${C_RESET}"
  say "${C_DIM}   Split (pat_str) → BPE (mergeable_ranks) → Specials${C_RESET}"
  rule
}

rust_backend_available() {
  # Heuristic: if a Rust backend package is present, it will show up in deps.
  # This stays conservative so pure Elixir users don't need Rust tooling.
  [[ -d "${ROOT}/deps/tiktoken_ex_rust" ]] && return 0
  grep -q "{:tiktoken_ex_rust," "${ROOT}/mix.lock" 2>/dev/null && return 0
  return 1
}

run_backend() {
  local backend="$1"
  local label="$2"
  local start_s end_s elapsed_s

  if [[ $ORACLE -eq 1 ]]; then
    info "Oracle parity: enabled"
  else
    info "Oracle parity: disabled (use --oracle)"
  fi

  say "${C_BOLD}${label}${C_RESET} ${C_DIM}(TIKTOKEN_EX_BACKEND=${backend})${C_RESET}"
  start_s=$(date +%s)

  local cmd=(mix test)
  if [[ $ORACLE -eq 1 ]]; then
    cmd+=(--include oracle)
  fi
  cmd+=("${MIX_ARGS[@]}")

  (
    cd "${ROOT}"
    TIKTOKEN_EX_BACKEND="${backend}" "${cmd[@]}"
  )

  end_s=$(date +%s)
  elapsed_s=$((end_s - start_s))
  ok "${label} passed in ${elapsed_s}s"
}

main() {
  banner

  local backends=("elixir" "rust")
  local any_fail=0
  local rust_avail=0

  if rust_backend_available; then
    rust_avail=1
  fi

  for backend in "${backends[@]}"; do
    if [[ -n "${ONLY_BACKEND}" ]] && [[ "${backend}" != "${ONLY_BACKEND}" ]]; then
      continue
    fi

    case "${backend}" in
      elixir)
        run_backend "elixir" "${C_PURPLE}Elixir Backend${C_RESET}" || any_fail=1
        ;;
      rust)
        if [[ $rust_avail -eq 0 ]]; then
          if [[ $REQUIRE_RUST -eq 1 ]]; then
            fail "Rust backend not available (install tiktoken_ex_rust); failing due to --require-rust"
            any_fail=1
          else
            warn "Rust backend not available (install tiktoken_ex_rust); skipping"
          fi
        else
          run_backend "rust" "${C_ORANGE}Rust Backend${C_RESET}" || any_fail=1
        fi
        ;;
      *)
        fail "Unknown backend: ${backend}"
        any_fail=1
        ;;
    esac

    rule
  done

  if [[ $any_fail -ne 0 ]]; then
    fail "Some backend runs failed"
    exit 1
  fi

  ok "All selected backend runs passed"
}

main

