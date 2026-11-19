#!/usr/bin/env bash
# cargo-deny: license and advisory findings in every Cargo workspace of this repo, checked
# against the repo-root deny.toml. deny.toml is a baseline: it allows every license and
# ignores every advisory the tree had when it was written, so a finding here is new since
# then. Report-only: exits 0 once cargo-deny ran on the workspaces (findings or not);
# nonzero only when it could not be installed or ran on none of them.
#
# findings = error diagnostics (one per crate per license rejection or advisory) per workspace.
# Needs cargo (cargo-deny reads `cargo metadata`, which may download crate sources).
#
# Usage: bash scripts/static-analysis/cargo-deny.sh [WORKSPACE_DIR...]
# Env: SA_TOOLS_DIR, FAST_CHECKS_OUT as in the other static-analysis scripts; SA_CARGO_DENY_CONFIG.
set -uo pipefail

VERSION="0.21.0"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "cargo-deny.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
TOOLS_DIR="${SA_TOOLS_DIR:-$HOME/.cache/static-analysis/bin}"
OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
mkdir -p "$TOOLS_DIR" "$OUT_DIR/cargo-deny" || exit 2
START=$(date +%s)
command -v cargo >/dev/null || { echo "cargo-deny.sh: cargo is required" >&2; exit 2; }

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  TARGET=x86_64-unknown-linux-musl;  SHA=a2170b854ff697e79e39c4c538981c9c1bdd803addbae6719a4cb66b4585a903 ;;
  Linux-aarch64) TARGET=aarch64-unknown-linux-musl; SHA=47cc5d88d43cd568028080fece02d729f56f0ff8e6c168563ce6589e3c0f4738 ;;
  Darwin-arm64)  TARGET=aarch64-apple-darwin;       SHA=c99a789160775ada8cb54aed72cfdae5a9b72e27434f8868d17c9634c3f52425 ;;
  *) echo "cargo-deny.sh: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac

BIN="$TOOLS_DIR/cargo-deny-$VERSION"
if [ ! -x "$BIN" ]; then
  TMP="$(mktemp -d)" || exit 2
  URL="https://github.com/EmbarkStudios/cargo-deny/releases/download/$VERSION/cargo-deny-$VERSION-$TARGET.tar.gz"
  curl -fsSL --retry 3 -o "$TMP/d.tgz" "$URL" || { echo "cargo-deny.sh: download failed: $URL" >&2; rm -rf "$TMP"; exit 2; }
  GOT="$( (sha256sum "$TMP/d.tgz" 2>/dev/null || shasum -a 256 "$TMP/d.tgz") | awk '{print $1}')"
  if [ "$GOT" != "$SHA" ]; then echo "cargo-deny.sh: sha256 mismatch ($GOT != $SHA)" >&2; rm -rf "$TMP"; exit 2; fi
  tar -xzf "$TMP/d.tgz" -C "$TMP" || { rm -rf "$TMP"; exit 2; }
  install -m 0755 "$TMP/cargo-deny-$VERSION-$TARGET/cargo-deny" "$BIN" || { rm -rf "$TMP"; exit 2; }
  rm -rf "$TMP"
fi

# Default: every workspace with a Cargo.lock (each lockfile is one resolved graph), the same
# set osv-scanner reads. vendor/ and ghostty* are third-party.
if [ "$#" -gt 0 ]; then
  DIRS=("$@")
else
  mapfile -t DIRS < <(git ls-files '*Cargo.lock' | grep -vE '^(vendor|ghostty|ghostty-next)/' | xargs -n1 dirname | sort -u)
fi

# SA_CARGO_DENY_CONFIG: another config (an empty one reports every license and advisory, which
# daily_findings.py --write-deny-toml turns into a new baseline).
CONFIG="${SA_CARGO_DENY_CONFIG:-$ROOT/deny.toml}"
[ -f "$CONFIG" ] || { echo "cargo-deny.sh: $CONFIG is missing" >&2; exit 2; }

RAN=0
FINDINGS=0
TXT="$OUT_DIR/cargo-deny.txt"
: >"$TXT"
for dir in "${DIRS[@]}"; do
  dir="${dir%/}"
  safe="${dir//\//__}"
  json="$OUT_DIR/cargo-deny/$safe.jsonl"
  # --locked: never rewrite a Cargo.lock. Exit 0 clean, 1..N findings; a crash prints no summary.
  "$BIN" --manifest-path "$dir/Cargo.toml" --config "$CONFIG" --format json --workspace --locked \
    check licenses advisories >"$json" 2>&1
  if ! grep -q '"type":"summary"' "$json"; then
    echo "cargo-deny.sh: $dir: cargo-deny did not finish (see $json)" >&2
    echo "## $dir: did not run" >>"$TXT"
    continue
  fi
  RAN=$((RAN + 1))
  n=$(jq -s '[.[] | select(.type == "diagnostic" and .fields.severity == "error")] | length' "$json")
  FINDINGS=$((FINDINGS + n))
  {
    echo "## $dir: $n"
    jq -r 'select(.type == "diagnostic" and .fields.severity == "error") | .fields
      | "  \(.code) \(.graphs[0].Krate.name // "-")@\(.graphs[0].Krate.version // "-") \(.advisory.id // .labels[0].span // "") \(.message)"' "$json"
  } >>"$TXT"
done

if [ "$RAN" -eq 0 ]; then echo "cargo-deny.sh: cargo-deny did not run on any workspace" >&2; exit 2; fi
head -60 "$TXT"
echo "Full report: $TXT (per-workspace JSON lines in $OUT_DIR/cargo-deny/)"
echo "SA_SUMMARY tool=cargo-deny findings=$FINDINGS seconds=$(( $(date +%s) - START ))"
exit 0
