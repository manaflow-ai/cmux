#!/usr/bin/env bash
# Report unused Rust dependencies in every Cargo package of this repo with cargo-machete.
# Report-only: exits 0 once the tool ran (findings or not); nonzero only if it could not
# be installed or crashed. Usage: bash scripts/static-analysis/cargo-machete.sh [DIR...]
# cargo-machete reads source text (no build), so it can miss macro/build.rs use: verify
# each finding by hand before deleting. Silence a verified false positive in that crate's
# Cargo.toml with [package.metadata.cargo-machete] ignored = ["dep"].
set -uo pipefail

VERSION="0.10.1"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "cargo-machete.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
TOOLS_DIR="${SA_TOOLS_DIR:-$HOME/.cache/static-analysis/bin}"
OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
OUT="$OUT_DIR/cargo-machete.txt"
mkdir -p "$TOOLS_DIR" "$OUT_DIR" || exit 2
START=$(date +%s)

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  TARGET=x86_64-unknown-linux-musl;  SHA=785d381985140ffa172246d82089adeb7f2eb9c774d961c48f77a4494023afb5 ;;
  Linux-aarch64) TARGET=aarch64-unknown-linux-musl; SHA=32271da65eee1b52af60aad7ed34c0466d05b58988fbaeadda510bcef5765282 ;;
  Darwin-arm64)  TARGET=aarch64-apple-darwin;       SHA=0659860970e26179d730d1a2e99fc6513e41fea122ad5451d7ae43234fc1ebab ;;
  Darwin-x86_64) TARGET=x86_64-apple-darwin;        SHA=19c7384d636a27032ff0b4695b67e79b75a366e5c0573b220bd12bc71b59b435 ;;
  *) echo "cargo-machete.sh: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac

BIN="$TOOLS_DIR/cargo-machete-$VERSION"
if [ ! -x "$BIN" ]; then
  TMP="$(mktemp -d)" || exit 2
  URL="https://github.com/bnjbvr/cargo-machete/releases/download/v$VERSION/cargo-machete-v$VERSION-$TARGET.tar.gz"
  curl -fsSL --retry 3 -o "$TMP/m.tgz" "$URL" || { echo "cargo-machete.sh: download failed: $URL" >&2; rm -rf "$TMP"; exit 2; }
  GOT="$( (sha256sum "$TMP/m.tgz" 2>/dev/null || shasum -a 256 "$TMP/m.tgz") | awk '{print $1}')"
  if [ "$GOT" != "$SHA" ]; then echo "cargo-machete.sh: sha256 mismatch ($GOT != $SHA)" >&2; rm -rf "$TMP"; exit 2; fi
  tar -xzf "$TMP/m.tgz" -C "$TMP" || { rm -rf "$TMP"; exit 2; }
  install -m 0755 "$TMP/cargo-machete-v$VERSION-$TARGET/cargo-machete" "$BIN" || { rm -rf "$TMP"; exit 2; }
  rm -rf "$TMP"
fi

# Default: the whole repo. machete walks every Cargo.toml it finds, honouring .gitignore,
# and skips target/ dirs. vendor/ and ghostty* are third-party; skip them.
if [ "$#" -gt 0 ]; then
  DIRS=("$@")
else
  # Outermost dirs only: machete recurses, so a nested root would be scanned twice.
  mapfile -t DIRS < <(git ls-files '*Cargo.toml' | grep -vE '^(vendor|ghostty|ghostty-next)/' | xargs -n1 dirname | sort -u \
    | awk '{ for (i = 1; i <= n; i++) if (index($0 "/", kept[i] "/") == 1) next; kept[++n] = $0; print }')
fi

# Plain mode reads sources only and needs no toolchain (--with-metadata would run cargo
# and may rewrite Cargo.lock files).
"$BIN" --skip-target-dir "${DIRS[@]}" >"$OUT" 2>&1
RC=$?
# machete exits 1 when it found unused deps, 0 when clean, 2+ on error.
if [ "$RC" -ge 2 ]; then
  cat "$OUT" >&2; echo "cargo-machete.sh: cargo-machete crashed (exit $RC)" >&2; exit 2
fi

# machete looks for the package name, so a dep whose [lib] name differs (cmux-sdk is
# `cmux`) always reads as unused. Re-check those by their lib name and mark them.
declare -A LIBNAME=()
while IFS= read -r toml; do
  read -r pkg lib < <(awk '
    /^\[/ { sec=$0 }
    sec=="[package]" && /^name[ \t]*=/ { gsub(/["\t ]/, ""); sub(/^name=/, ""); p=$0 }
    sec=="[lib]" && /^name[ \t]*=/ { gsub(/["\t ]/, ""); sub(/^name=/, ""); l=$0 }
    END { if (p != "" && l != "" && l != p) print p, l }' "$toml")
  [ -n "${pkg:-}" ] && LIBNAME[$pkg]=$lib
  pkg="" lib=""
done < <(git ls-files '*Cargo.toml')
TAB="$(printf '\t')"
FINDINGS=0
NOTED="$(mktemp)" || exit 2
crate_dir=""
while IFS= read -r line; do
  if [[ "$line" =~ \ --\ (.*)/Cargo\.toml:$ ]]; then crate_dir="${BASH_REMATCH[1]}"
  elif [[ "$line" == "$TAB"* ]]; then
    dep="${line#"$TAB"}"; dep="${dep%% *}"; lib="${LIBNAME[$dep]:-}"
    if [ -n "$lib" ] && grep -rqE --include='*.rs' "(\\b${lib}::|use ${lib}\\b|extern crate ${lib}\\b)" "$crate_dir"; then
      line="$line  (not counted: lib name \`$lib\` is used; machete only knows the package name)"
    else
      FINDINGS=$((FINDINGS + 1))
    fi
  fi
  printf '%s\n' "$line"
done <"$OUT" >"$NOTED"
mv "$NOTED" "$OUT" || exit 2
grep -v 'Good job!$' "$OUT"
echo "Full report: $OUT"
echo "SA_SUMMARY tool=cargo-machete findings=${FINDINGS:-0} seconds=$(( $(date +%s) - START ))"
exit 0
