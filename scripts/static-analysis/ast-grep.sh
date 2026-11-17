#!/usr/bin/env bash
# ast-grep: structural rules for Rust, Swift and TypeScript (scripts/static-analysis/ast-grep/rules).
# Most are ports of regex detectors (check-spawn-owner.py, lint-connection-lifetimes.py R3/R4,
# check-concurrency.sh's unowned-Task rule) that match calls in the syntax tree instead of text, so
# comments and strings never match. Report-only: the originals stay the gates.
# Exits 0 when ast-grep ran (findings or not); nonzero only when it could not be installed or crashed.
#
# Env:
#   AST_GREP_PATHS    paths to scan, space-separated (default: the repo root; each rule's `files` scopes it)
#   SA_TOOLS_DIR, FAST_CHECKS_OUT as in the other static-analysis scripts
set -uo pipefail

AST_GREP_VERSION=0.51.3
AST_GREP_SHA256_X64=22803eb0c5bf83164fb7fd76d4721d355ecf0c8466ef47342c1ec7d80897ca47
AST_GREP_SHA256_ARM64=5b44fd68e78744934b359b07badce347d4197ed50b341d50f1f99d056ecedb08

OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
ROOT="$(git rev-parse --show-toplevel)" || { echo "ast-grep.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
mkdir -p "$OUT_DIR" || exit 2
TOOLS_DIR="${SA_TOOLS_DIR:-$HOME/.cache/static-analysis/bin}"
mkdir -p "$TOOLS_DIR" || exit 2
start=$(date +%s)

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

install_ast_grep() {
  local bin="$TOOLS_DIR/ast-grep-$AST_GREP_VERSION"
  if [ -x "$bin" ]; then echo "$bin"; return 0; fi
  local plat sha
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) plat=x86_64-unknown-linux-gnu; sha=$AST_GREP_SHA256_X64 ;;
    Linux-aarch64|Linux-arm64) plat=aarch64-unknown-linux-gnu; sha=$AST_GREP_SHA256_ARM64 ;;
    *) echo "ast-grep.sh: unsupported platform $(uname -s)-$(uname -m)" >&2; return 1 ;;
  esac
  local tmp; tmp="$(mktemp -d)" || return 1
  local zip="$tmp/ast-grep.zip"
  curl -fsSL --retry 3 -o "$zip" \
    "https://github.com/ast-grep/ast-grep/releases/download/$AST_GREP_VERSION/app-$plat.zip" || { rm -rf "$tmp"; return 1; }
  if [ "$(sha256_of "$zip")" != "$sha" ]; then echo "ast-grep.sh: sha256 mismatch" >&2; rm -rf "$tmp"; return 1; fi
  # The zip holds `ast-grep` and its `sg` alias; unzip may be missing on a fresh runner, Python is not.
  mkdir "$tmp/x" && python3 -I -m zipfile -e "$zip" "$tmp/x" || { rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/x/ast-grep" "$bin" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "$bin"
}

AST_GREP="$(install_ast_grep)" || { echo "ast-grep.sh: install failed" >&2; exit 3; }

cfg=scripts/static-analysis/ast-grep/sgconfig.yml
read -r -a paths <<<"${AST_GREP_PATHS:-.}"
raw="$OUT_DIR/ast-grep.jsonl"
"$AST_GREP" scan -c "$cfg" --json=stream --include-metadata "${paths[@]}" >"$raw" 2>"$OUT_DIR/ast-grep.log"
rc=$?
# ast-grep exits 1 only for error-severity findings; these rules are warnings, so any nonzero is a crash.
if [ "$rc" -ne 0 ]; then
  echo "ast-grep.sh: ast-grep crashed (exit $rc)" >&2; tail -20 "$OUT_DIR/ast-grep.log" >&2; exit 4
fi

txt="$OUT_DIR/ast-grep.txt"
findings=$(python3 -I scripts/static-analysis/ast-grep/filter.py "$txt" "$OUT_DIR/ast-grep.json" <"$raw") \
  || { echo "ast-grep.sh: could not read ast-grep's output" >&2; exit 4; }
head -30 "$txt"
echo "full report: $txt"
echo "SA_SUMMARY tool=ast-grep findings=$findings seconds=$(( $(date +%s) - start ))"
exit 0
