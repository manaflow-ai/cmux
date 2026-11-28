#!/usr/bin/env bash
# toolchain-r2.sh restore|seed node VERSION | bun VERSION | rust [TOOLCHAIN_FILE]
#
# The pinned Node, Bun and Rust toolchains, kept in the CI cache bucket (r2-cache.sh) so a Freestyle runner
# installs them from the bucket instead of nodejs.org, github.com and static.rust-lang.org. Same shape as
# zig-tarball-r2.sh. Node and Bun also restore on macOS (the nightly Macs), Rust on Linux only.
#
# Why: Freestyle runners read those hosts at about 0.3-1 MB/s. Over 24 h on 2026-11-23 the measured install
# steps took (p50 / p90 s): Setup Node 190 / 697, Setup Bun 96 / 580, Set up pinned Rust 522 / 1357,
# Set up pinned cmux-tui Rust 377 / 1445, about 14,000 runner minutes a day. On the self-hosted nightly Macs
# github.com refuses setup-bun's anonymous release download outright (403, runs 45765712386 and 45756842046 on
# 2026-11-26); their restore steps set TOOLCHAIN_R2_ALL=1 so setup-bun finds Bun in place and reads nothing.
#
# restore: runs only on a Freestyle runner (RUNNER_NAME fsr-*; TOOLCHAIN_R2_ALL=1 runs anywhere) that lacks
#   the exact version, and puts it where the real installer looks first, so the installer then downloads
#   nothing: node in RUNNER_TOOL_CACHE/node/VERSION/ARCH (actions/setup-node), bun at ~/.bun/bin/bun
#   (oven-sh/setup-bun), rust in RUSTUP_HOME/toolchains (rustup toolchain install). Node and Bun archives are
#   the upstream ones and must match scripts/ci/toolchain-archives.sha256; the Rust toolchain must run and
#   report the pinned version. Every error is a miss and exits 0: the upstream installer still runs and
#   still works.
# seed: when the bucket has no copy, download from upstream (node and bun: checked against the pins file),
#   and save with the bucket's write credentials. `seed all` seeds every Node and Bun pin, each into its own
#   platform's namespace (macOS-ARM64 for a darwin-arm64 archive: verified bytes, nothing runs them, so the
#   Linux seeder fills the Macs' keys too), and this runner's Rust.
#
# TOOLCHAIN_R2_URL is the bucket's public URL (default https://ci-cache-next.cmux.com under GitHub Actions;
# empty turns it off).
set -euo pipefail

mode="${1:-}"
kind="${2:-}"
version="${3:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
r2_cache="$root/scripts/ci/r2-cache.sh"
pins="${TOOLCHAIN_PINS_FILE:-$root/scripts/ci/toolchain-archives.sha256}"
if [[ "$mode" != restore && "$mode" != seed ]] || [[ "$kind" != node && "$kind" != bun && "$kind" != rust && "$kind" != all ]] \
    || { [[ "$kind" == node || "$kind" == bun ]] && [[ -z "$version" ]]; }; then
  echo "usage: toolchain-r2.sh restore|seed node VERSION | bun VERSION | rust [TOOLCHAIN_FILE]" >&2
  exit 2
fi
[[ "$kind" == all && "$mode" == seed ]] || [[ "$kind" != all ]] || { echo "toolchain-r2: all is for seed" >&2; exit 2; }

url="${TOOLCHAIN_R2_URL-}"
if [[ -z "${TOOLCHAIN_R2_URL+set}" && "${GITHUB_ACTIONS:-}" == true ]]; then
  url=https://ci-cache-next.cmux.com
fi
namespace="${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}"
say() { echo "toolchain-r2: $*"; }

# bun answers "error: EACCES accessing temporary directory. set $BUN_TMPDIR or $BUN_INSTALL" when the system temp
# dir is not writable to the runner user: 6 of 22 gallery-health shards of batch run 46058976708 (hetzner-1-14,
# -1-21, -1-25, -2-16, -2-19, -2-23; 11-27 20:17Z) failed at their first bun install so, and the bisect's probes
# chased those legs. Every bun step after this one gets a temp dir under the runner's own $RUNNER_TEMP, which it
# owns, on every runner and before any early exit below (scripts/cmux-next/build-web-bundles.sh and
# fast_gate_webviews_checks.py fixed it for themselves alone).
bun_tmpdir() {
  [[ -z "${BUN_TMPDIR:-}" && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]] || return 0
  mkdir -p "$RUNNER_TEMP/bun-tmp" 2>/dev/null && [[ -w "$RUNNER_TEMP/bun-tmp" ]] || return 0
  echo "BUN_TMPDIR=$RUNNER_TEMP/bun-tmp" >> "$GITHUB_ENV"
  say "BUN_TMPDIR=$RUNNER_TEMP/bun-tmp for the job's bun steps"
}

[[ "$mode" != restore || "$kind" != bun ]] || bun_tmpdir
scratch=()
trap 'for d in ${scratch[@]+"${scratch[@]}"}; do rm -rf "$d"; done' EXIT

# restore bun, on any runner (Macs too): the minis share ~/.bun between runner instances and other jobs leave
# another bun there (cmux7s-mac-mini, 11-26 07:00Z: ~/.bun/bin/bun was 1.4.5), so setup-bun downloaded 1.4.4 from
# github.com and failed the nightly on a 403 (run 45771452504). Keep each version seen at ~/.bun/bin/bun in a
# version-keyed store and put the pinned one back first, so setup-bun downloads nothing.
bun_store_dir="${TOOLCHAIN_BUN_STORE:-$HOME/.cache/cmux-toolchains/bun}"
bun_store_keep() { # BIN: keep a copy of BIN under its own version
  local b="$1" v
  v="$("$b" --version 2>/dev/null)" || return 0
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  [[ -x "$bun_store_dir/$v/bun" ]] && return 0
  mkdir -p "$bun_store_dir/$v" && cp "$b" "$bun_store_dir/$v/bun.tmp.$$" && mv -f "$bun_store_dir/$v/bun.tmp.$$" "$bun_store_dir/$v/bun" \
    && say "kept bun $v in $bun_store_dir/$v" || true
}
if [[ "$mode" == restore && "$kind" == bun ]]; then
  shared_bun="$HOME/.bun/bin/bun"
  [[ -x "$shared_bun" ]] && bun_store_keep "$shared_bun"
  if [[ -x "$shared_bun" && "$("$shared_bun" --version 2>/dev/null)" == "$version" ]]; then
    say "bun $version is at $shared_bun"; exit 0
  fi
  if [[ -x "$bun_store_dir/$version/bun" && "$("$bun_store_dir/$version/bun" --version 2>/dev/null)" == "$version" ]]; then
    mkdir -p "$(dirname "$shared_bun")"
    if cp "$bun_store_dir/$version/bun" "$shared_bun.tmp.$$" && mv -f "$shared_bun.tmp.$$" "$shared_bun"; then
      say "bun $version put back at $shared_bun from $bun_store_dir/$version (no download)"; exit 0
    fi
  fi
fi

if [[ "$mode" == restore ]]; then
  if [[ -z "$url" ]]; then say "no cache URL; nothing to restore"; exit 0; fi
  case "${RUNNER_NAME:-}" in
    fsr-*) ;;
    *) [[ "${TOOLCHAIN_R2_ALL:-}" == 1 ]] || { say "not a Freestyle runner; the installer is left alone"; exit 0; } ;;
  esac
fi

case "$(uname -s)" in
  Linux) plat=linux ;;
  Darwin) plat=darwin ;;
  *) say "Linux and macOS only"; exit 0 ;;
esac
case "$(uname -m)" in
  x86_64) node_arch=x64 bun_arch=x64 triple=x86_64-unknown-linux-gnu ;;
  aarch64 | arm64) node_arch=arm64 bun_arch=aarch64 triple=aarch64-unknown-linux-gnu ;;
  *) say "unsupported arch $(uname -m)"; exit 0 ;;
esac
if [[ "$plat" == darwin && "$kind" == rust ]]; then say "Rust is Linux only"; exit 0; fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
  else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}
pin_of() { awk -v f="$1" '$1 !~ /^#/ && $2 == f { print $1 }' "$pins"; }
r2() { # NAMESPACE restore|save DIR KEY
  local ns="$1"; shift
  CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$ns" GITHUB_OUTPUT='' bash "$r2_cache" "$@"
}
key_held() { # NAMESPACE KEY
  local extension
  for extension in tar.zst tar.gz; do
    curl --fail --silent --head --location --connect-timeout 15 --max-time 60 \
      "${url%/}/v1/$1/objects/$2.$extension" >/dev/null && return 0
  done
  return 1
}
need_write() {
  local var
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET; do
    [[ -n "${!var:-}" ]] || { echo "toolchain-r2: seed needs $var (the bucket's write credentials)" >&2; exit 2; }
  done
}

archive_name() { # KIND VERSION: this runner's archive
  if [[ "$1" == node ]]; then echo "node-v$2-$plat-$node_arch.tar.gz"; else echo "bun-v$2-$plat-$bun_arch.zip"; fi
}
archive_key() { # ARCHIVE-NAME -> key; the pin's prefix moves the key when the pin moves
  echo "toolchain-$1-$(pin_of "$1" | cut -c1-16)"
}
archive_namespace() { # ARCHIVE-NAME -> the r2-cache.sh namespace (RUNNER_OS-RUNNER_ARCH) of the platform it is for
  case "$1" in
    *-linux-x64.*) echo Linux-X64 ;;
    *-linux-arm64.* | *-linux-aarch64.*) echo Linux-ARM64 ;;
    *-darwin-x64.*) echo macOS-X64 ;;
    *-darwin-arm64.* | *-darwin-aarch64.*) echo macOS-ARM64 ;;
    *) return 1 ;;
  esac
}
upstream_url() { # ARCHIVE-NAME
  local v="${1#*-v}"; v="${v%%-*}"
  case "$1" in
    node-v*) echo "https://nodejs.org/dist/v$v/$1" ;;
    bun-v*) echo "https://github.com/oven-sh/bun/releases/download/bun-v$v/bun-${1#bun-v"$v"-}" ;;
  esac
}

# Rust: the pinned channel, profile and components of the toolchain file.
rust_pin() {
  local file="${1:-$root/cmux-tui/rust-toolchain.toml}"
  channel="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1)"
  profile="$(sed -n 's/^[[:space:]]*profile[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1)"
  components="$(sed -n 's/^[[:space:]]*components[[:space:]]*=[[:space:]]*\[\([^]]*\)\].*/\1/p' "$file" | head -1 | tr -d '" ' | tr ',' ' ')"
  [[ -n "$channel" && -n "$profile" ]] || { say "no channel and profile in $file"; return 1; }
  rust_name="$channel-$triple"
  rust_key="toolchain-rust-$rust_name-$profile-$(echo "$components" | tr ' ' '-')-v1"
}

restore_node() {
  local ver="$version" tool name work dir expected stage
  [[ -n "${RUNNER_TOOL_CACHE:-}" ]] || { say "no RUNNER_TOOL_CACHE"; return 0; }
  tool="$RUNNER_TOOL_CACHE/node/$ver/$node_arch"
  if [[ -f "$tool.complete" ]]; then say "node $ver is in the tool cache"; return 0; fi
  name="$(archive_name node "$ver")"
  expected="$(pin_of "$name")"
  [[ -n "$expected" ]] || { say "no pin for $name; setup-node downloads it"; return 0; }
  work="$(mktemp -d)"; scratch+=("$work")
  restore_archive "$name" "$work" || return 0
  mkdir -p "$(dirname "$tool")"
  stage="$(mktemp -d "$tool.XXXXXX")"; scratch+=("$stage")
  if tar -xzf "$work/$name" -C "$stage" --strip-components=1 && [[ "$("$stage/bin/node" --version 2>/dev/null)" == "v$ver" ]]; then
    rm -rf "$tool"
    mv "$stage" "$tool" && touch "$tool.complete" && say "node $ver restored into $tool"
  else
    say "the copy of $name did not unpack to node v$ver; setup-node downloads it"
  fi
  rm -rf "$stage"
}

restore_archive() { # NAME WORKDIR: fills WORKDIR/NAME with the bucket's copy when it matches its pin
  local name="$1" work="$2" t0 got
  t0="$(date +%s)"
  mkdir -p "$work/get"
  r2 "$(archive_namespace "$name")" restore "$work/get" "$(archive_key "$name")" >/dev/null 2>&1 || true
  if [[ ! -f "$work/get/$name" ]]; then say "no cached $name; the installer downloads it"; return 1; fi
  got="$(sha256_of "$work/get/$name")"
  if [[ "$got" != "$(pin_of "$name")" ]]; then say "the cached $name does not match its pin; discarded"; return 1; fi
  mv "$work/get/$name" "$work/$name"
  say "fetched $name in $(( $(date +%s) - t0 )) s, sha256 matches the pin"
}

restore_bun() {
  local ver="$version" bin="$HOME/.bun/bin/bun" name work expected
  if [[ -x "$bin" && "$("$bin" --version 2>/dev/null)" == "$ver" ]]; then say "bun $ver is at $bin"; return 0; fi
  name="$(archive_name bun "$ver")"
  [[ -n "$(pin_of "$name")" ]] || { say "no pin for $name; setup-bun downloads it"; return 0; }
  work="$(mktemp -d)"; scratch+=("$work")
  restore_archive "$name" "$work" || return 0
  python3 -I - "$work/$name" "$work/out" <<'PY' || { say "the copy of $name would not unpack; setup-bun downloads it"; return 0; }
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1])
members = [m for m in z.namelist() if m.endswith("/bun") and m.count("/") == 1]
if len(members) != 1:
    raise SystemExit("no bun in the zip")
os.makedirs(sys.argv[2])
with z.open(members[0]) as src, open(os.path.join(sys.argv[2], "bun"), "wb") as dst:
    dst.write(src.read())
PY
  chmod 755 "$work/out/bun"
  if [[ "$("$work/out/bun" --version 2>/dev/null)" != "$ver" ]]; then say "the copy of $name is not bun $ver; setup-bun downloads it"; return 0; fi
  mkdir -p "$(dirname "$bin")"
  cp "$work/out/bun" "$bin.tmp.$$" && mv -f "$bin.tmp.$$" "$bin" && say "bun $ver restored to $bin" && bun_store_keep "$bin"
}

restore_rust() {
  local rustup_home="${RUSTUP_HOME:-$HOME/.rustup}" work t0 f
  rust_pin "${version:-}" || return 0
  if [[ -x "$rustup_home/toolchains/$rust_name/bin/rustc" ]] && "$rustup_home/toolchains/$rust_name/bin/rustc" --version >/dev/null 2>&1; then
    say "Rust $channel is installed"; return 0
  fi
  t0="$(date +%s)"
  work="$(mktemp -d)"; scratch+=("$work")
  r2 "$namespace" restore "$work/get" "$rust_key" >/dev/null 2>&1 || true
  if [[ ! -x "$work/get/toolchains/$rust_name/bin/rustc" ]]; then say "no cached $rust_key; rustup downloads it"; return 0; fi
  if [[ "$("$work/get/toolchains/$rust_name/bin/rustc" --version 2>/dev/null)" != "rustc $channel "* ]]; then
    say "the cached $rust_key does not run as Rust $channel; discarded"; return 0
  fi
  mkdir -p "$rustup_home/toolchains" "$rustup_home/update-hashes"
  rm -rf "$rustup_home/toolchains/$rust_name"
  mv "$work/get/toolchains/$rust_name" "$rustup_home/toolchains/$rust_name"
  [[ ! -f "$work/get/update-hashes/$rust_name" ]] || cp "$work/get/update-hashes/$rust_name" "$rustup_home/update-hashes/$rust_name"
  if ! command -v rustup >/dev/null 2>&1 && [[ ! -x "$HOME/.cargo/bin/rustup" && -x "$work/get/cargo-bin/rustup" ]]; then
    mkdir -p "$HOME/.cargo/bin"
    cp "$work/get/cargo-bin/rustup" "$HOME/.cargo/bin/rustup"
    for f in "$work"/get/cargo-bin/*; do
      [[ "$(basename "$f")" == rustup ]] || ln -sf rustup "$HOME/.cargo/bin/$(basename "$f")"
    done
  fi
  say "Rust $channel restored in $(( $(date +%s) - t0 )) s"
}

restore_one() {
  case "$kind" in node) restore_node ;; bun) restore_bun ;; rust) restore_rust ;; esac
}

seed_archive() { # ARCHIVE-NAME
  local name="$1" key work ns
  [[ -n "$(pin_of "$name")" ]] || { echo "toolchain-r2: no pin for $name" >&2; return 1; }
  ns="$(archive_namespace "$name")" || { echo "toolchain-r2: no platform in $name" >&2; return 1; }
  key="$(archive_key "$name")"
  if key_held "$ns" "$key"; then say "the cache already holds $key"; return 0; fi
  work="$(mktemp -d)"; scratch+=("$work")
  mkdir -p "$work/dir"
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 900 -o "$work/dir/$name" "$(upstream_url "$name")"
  [[ "$(sha256_of "$work/dir/$name")" == "$(pin_of "$name")" ]] \
    || { echo "::error::toolchain-r2: $name does not match scripts/ci/toolchain-archives.sha256" >&2; return 1; }
  r2 "$ns" save "$work/dir" "$key"
}

seed_rust() {
  local work
  rust_pin "${version:-}" || return 1
  if key_held "$namespace" "$rust_key"; then say "the cache already holds $rust_key"; return 0; fi
  work="$(mktemp -d)"; scratch+=("$work")
  mkdir -p "$work/cargo" "$work/rustup" "$work/dir/toolchains" "$work/dir/update-hashes" "$work/dir/cargo-bin"
  curl --proto '=https' --tlsv1.2 -sSf --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 -o "$work/rustup-init.sh" https://sh.rustup.rs
  RUSTUP_HOME="$work/rustup" CARGO_HOME="$work/cargo" RUSTUP_INIT_SKIP_PATH_CHECK=yes \
    sh "$work/rustup-init.sh" -y --profile minimal --default-toolchain none --no-modify-path
  local args=(toolchain install "$channel" --profile "$profile") c
  for c in $components; do args+=(--component "$c"); done
  RUSTUP_HOME="$work/rustup" CARGO_HOME="$work/cargo" "$work/cargo/bin/rustup" "${args[@]}"
  [[ "$("$work/rustup/toolchains/$rust_name/bin/rustc" --version)" == "rustc $channel "* ]] \
    || { echo "::error::toolchain-r2: the installed toolchain is not Rust $channel" >&2; return 1; }
  mv "$work/rustup/toolchains/$rust_name" "$work/dir/toolchains/$rust_name"
  cp "$work/rustup/update-hashes/$rust_name" "$work/dir/update-hashes/$rust_name"
  cp "$work/cargo/bin/rustup" "$work/dir/cargo-bin/rustup"
  for c in "$work"/cargo/bin/*; do
    [[ "$(basename "$c")" == rustup ]] || ln -s rustup "$work/dir/cargo-bin/$(basename "$c")"
  done
  r2 "$namespace" save "$work/dir" "$rust_key"
}

if [[ "$mode" == restore ]]; then
  restore_one
  exit 0
fi

[[ -n "$url" ]] || { echo "toolchain-r2: seed needs TOOLCHAIN_R2_URL (the bucket's public URL)" >&2; exit 2; }
need_write
case "$kind" in
  node | bun) seed_archive "$(archive_name "$kind" "$version")" ;;
  rust) seed_rust ;;
  all)
    status=0
    while read -r _ name; do
      case "$name" in
        node-v*.tar.gz | bun-v*.zip) seed_archive "$name" || status=1 ;;
      esac
    done < <(grep -v '^#' "$pins")
    seed_rust || status=1
    exit "$status"
    ;;
esac
