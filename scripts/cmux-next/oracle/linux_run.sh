#!/usr/bin/env bash
# Build the cmux-tui daemon the correctness oracle runs, on a Linux runner.
#
#   linux_run.sh build [REF] [--checkout DIR] [--target-dir DIR] [--receipt FILE] [--leaf-rebuild]
#
# Builds `cargo build --profile oracle --features oracle -p cmux-tui` (cmux-tui/Cargo.toml
# [profile.oracle]: release code generation with debug assertions and overflow checks, no LTO,
# 256 codegen units, line tables) in the checkout DIR (default: this script's repository).
# The last stdout line is the cmux-tui binary path (the contract oracle.py's build_daemon
# reads); cargo's output goes to stderr. The receipt JSON records the SHA, the ghostty-next
# gitlink, the toolchain and the build times; with --leaf-rebuild it also records a rebuild
# after touching the leaf crate's root (crates/cmux-tui/src/main.rs).
#
# REF, when given, must be the checkout's HEAD: per-SHA worktrees are p15-oracle-024.
# The VT library always comes from the checkout's own ghostty-next submodule: an inherited
# CMUX_GHOSTTY_SRC would build every SHA against one VT source, so it is cleared.
#
# Spec: plans/cmux-next/chrome-parity/p15-oracle.md, task 201.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE="oracle"
FEATURES="oracle"

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "linux_run.sh: $1" >&2
  exit "${2:-1}"
}

now() {
  # EPOCHREALTIME (bash 5) has microseconds; the runner is Linux.
  echo "${EPOCHREALTIME/,/.}"
}

elapsed_ms() {
  python3 -I -c 'import sys; print(round((float(sys.argv[2]) - float(sys.argv[1])) * 1000))' "$1" "$2"
}

run_cargo() {
  local manifest="$1" target_dir="$2"
  # stdout of cargo carries nothing we need; keep ours for the binary path alone.
  nice -n 10 env CMUX_GHOSTTY_SRC= CARGO_TARGET_DIR="$target_dir" \
    cargo build --locked --manifest-path "$manifest" \
    --profile "$PROFILE" --features "$FEATURES" -p cmux-tui >&2
}

cmd_build() {
  local ref="" checkout="" target_dir="" receipt="" leaf_rebuild=0
  while (($#)); do
    case "$1" in
      --checkout) checkout="${2:?--checkout needs a directory}"; shift 2 ;;
      --target-dir) target_dir="${2:?--target-dir needs a directory}"; shift 2 ;;
      --receipt) receipt="${2:?--receipt needs a file}"; shift 2 ;;
      --leaf-rebuild) leaf_rebuild=1; shift ;;
      -h|--help) usage ;;
      -*) die "unknown option $1" 2 ;;
      *) [[ -z "$ref" ]] || die "one REF only" 2; ref="$1"; shift ;;
    esac
  done

  [[ "$(uname -s)" == "Linux" ]] || die "the oracle daemon build runs on Linux only" 2
  checkout="$(cd "${checkout:-$SCRIPT_DIR/../../..}" && pwd -P)"
  local manifest="$checkout/cmux-tui/Cargo.toml"
  [[ -f "$manifest" ]] || die "$checkout is not a cmux checkout (no cmux-tui/Cargo.toml)" 2
  grep -q '^\[profile\.oracle\]' "$manifest" || die "$manifest has no [profile.oracle]" 2

  local sha
  sha="$(git -C "$checkout" rev-parse HEAD)"
  if [[ -n "$ref" ]]; then
    local ref_sha
    ref_sha="$(git -C "$checkout" rev-parse --verify --quiet "$ref^{commit}")" \
      || die "unknown ref $ref" 2
    [[ "$ref_sha" == "$sha" ]] \
      || die "$ref is $ref_sha, the checkout is at $sha; per-SHA worktrees are p15-oracle-024" 2
  fi
  [[ -f "$checkout/ghostty-next/build.zig" ]] \
    || die "ghostty-next is not checked out in $checkout (git submodule update --init ghostty-next)" 2
  local gitlink
  gitlink="$(git -C "$checkout" rev-parse "HEAD:ghostty-next")"
  local vt_head
  vt_head="$(git -C "$checkout/ghostty-next" rev-parse HEAD)"
  [[ "$vt_head" == "$gitlink" ]] \
    || die "ghostty-next is at $vt_head, the gitlink at $sha is $gitlink" 2

  target_dir="${target_dir:-$checkout/cmux-tui/target}"
  mkdir -p "$target_dir"
  target_dir="$(cd "$target_dir" && pwd -P)"
  local binary="$target_dir/$PROFILE/cmux-tui"
  local state="cold"
  [[ -e "$binary" ]] && state="warm"

  local t0 t1 build_ms leaf_ms=""
  t0="$(now)"
  run_cargo "$manifest" "$target_dir"
  t1="$(now)"
  build_ms="$(elapsed_ms "$t0" "$t1")"
  echo "linux_run.sh: $state build of $sha in ${build_ms} ms" >&2

  if ((leaf_rebuild)); then
    touch "$checkout/cmux-tui/crates/cmux-tui/src/main.rs"
    t0="$(now)"
    run_cargo "$manifest" "$target_dir"
    t1="$(now)"
    leaf_ms="$(elapsed_ms "$t0" "$t1")"
    echo "linux_run.sh: leaf rebuild of $sha in ${leaf_ms} ms" >&2
  fi

  [[ -x "$binary" ]] || die "cargo finished but $binary is missing"

  receipt="${receipt:-$target_dir/$PROFILE/oracle-build-receipt.json}"
  mkdir -p "$(dirname "$receipt")"
  python3 -I - "$receipt" "$sha" "$gitlink" "$PROFILE" "$FEATURES" "$target_dir" "$state" \
    "$build_ms" "$leaf_ms" "$binary" "$checkout/cmux-tui" <<'PY'
import hashlib, json, os, platform, subprocess, sys
(out_path, sha, gitlink, profile, features, target_dir, state, build_ms, leaf_ms, binary,
 workspace) = sys.argv[1:]
digest = hashlib.sha256()
with open(binary, "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
rustc = subprocess.run(["rustc", "--version"], cwd=workspace, check=True,
                       stdout=subprocess.PIPE, text=True).stdout.strip()
receipt = {
    "schema": "cmux-oracle-build-v1",
    "sha": sha,
    "ghosttyNext": gitlink,
    "profile": profile,
    "features": [features],
    "package": "cmux-tui",
    "rustc": rustc,
    "host": {"name": platform.node(), "os": platform.system(), "arch": platform.machine(),
             "cpus": os.cpu_count()},
    "targetDir": target_dir,
    "state": state,
    "buildMs": int(build_ms),
    "leafRebuildMs": int(leaf_ms) if leaf_ms else None,
    "binary": binary,
    "binarySha256": digest.hexdigest(),
}
with open(out_path, "w", encoding="utf-8") as out:
    json.dump(receipt, out, indent=2, sort_keys=True)
    out.write("\n")
PY
  echo "linux_run.sh: receipt $receipt" >&2
  echo "$binary"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  -h|--help|"") usage ;;
  *) die "unknown command $1 (commands: build)" 2 ;;
esac
