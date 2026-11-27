#!/usr/bin/env bash
# toolchain-r2.sh restore|seed node VERSION | bun VERSION | rust [TOOLCHAIN_FILE]
#
# The pinned Node, Bun and Rust toolchains, kept in the CI cache bucket (r2-cache.sh) so a Freestyle runner
# installs them from the bucket instead of nodejs.org, github.com and static.rust-lang.org. Same shape as
# zig-tarball-r2.sh.
#
# Why: Freestyle runners read those hosts at about 0.3-1 MB/s. Over 24 h on 2026-11-23 the measured install
# steps took (p50 / p90 s): Setup Node 190 / 697, Setup Bun 96 / 580, Set up pinned Rust 522 / 1357,
# Set up pinned cmux-tui Rust 377 / 1445, about 14,000 runner minutes a day.
#
# restore: runs only on a Freestyle runner (RUNNER_NAME fsr-*; TOOLCHAIN_R2_ALL=1 runs anywhere) that lacks
#   the exact version, and puts it where the real installer looks first, so the installer then downloads
#   nothing: node in RUNNER_TOOL_CACHE/node/VERSION/ARCH (actions/setup-node), bun at ~/.bun/bin/bun
#   (oven-sh/setup-bun), rust in RUSTUP_HOME/toolchains (rustup toolchain install). Node and Bun archives are
#   the upstream ones and must match scripts/ci/toolchain-archives.sha256; the Rust toolchain must run and
#   report the pinned version. Every error is a miss and exits 0: the upstream installer still runs and
#   still works.
# seed: when the bucket has no copy, download from upstream (node and bun: checked against the pins file),
#   and save with the bucket's write credentials. `seed all` seeds every pin of this runner's arch and Rust.
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
scratch=()
trap 'for d in ${scratch[@]+"${scratch[@]}"}; do rm -rf "$d"; done' EXIT

if [[ "$mode" == restore ]]; then
  if [[ -z "$url" ]]; then say "no cache URL; nothing to restore"; exit 0; fi
  case "${RUNNER_NAME:-}" in
    fsr-*) ;;
    *) [[ "${TOOLCHAIN_R2_ALL:-}" == 1 ]] || { say "not a Freestyle runner; the installer is left alone"; exit 0; } ;;
  esac
fi

case "$(uname -s)" in Linux) ;; *) say "Linux only"; exit 0 ;; esac
case "$(uname -m)" in
  x86_64) node_arch=x64 bun_arch=x64 triple=x86_64-unknown-linux-gnu ;;
  aarch64 | arm64) node_arch=arm64 bun_arch=aarch64 triple=aarch64-unknown-linux-gnu ;;
  *) say "unsupported arch $(uname -m)"; exit 0 ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
  else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}
pin_of() { awk -v f="$1" '$1 !~ /^#/ && $2 == f { print $1 }' "$pins"; }
r2() { # restore|save DIR KEY
  CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$namespace" GITHUB_OUTPUT='' bash "$r2_cache" "$@"
}
key_held() { # KEY
  local extension
  for extension in tar.zst tar.gz; do
    curl --fail --silent --head --location --connect-timeout 15 --max-time 60 \
      "${url%/}/v1/$namespace/objects/$1.$extension" >/dev/null && return 0
  done
  return 1
}
need_write() {
  local var
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET; do
    [[ -n "${!var:-}" ]] || { echo "toolchain-r2: seed needs $var (the bucket's write credentials)" >&2; exit 2; }
  done
}

archive_name() { # KIND VERSION
  if [[ "$1" == node ]]; then echo "node-v$2-linux-$node_arch.tar.gz"; else echo "bun-v$2-linux-$bun_arch.zip"; fi
}
archive_key() { # ARCHIVE-NAME -> key; the pin's prefix moves the key when the pin moves
  echo "toolchain-$1-$(pin_of "$1" | cut -c1-16)"
}
upstream_url() { # KIND VERSION
  if [[ "$1" == node ]]; then echo "https://nodejs.org/dist/v$2/$(archive_name node "$2")"
  else echo "https://github.com/oven-sh/bun/releases/download/bun-v$2/$(archive_name bun "$2" | sed 's/^bun-v[0-9.]*-/bun-/')"; fi
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
  r2 restore "$work/get" "$(archive_key "$name")" >/dev/null 2>&1 || true
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
  cp "$work/out/bun" "$bin.tmp.$$" && mv -f "$bin.tmp.$$" "$bin" && say "bun $ver restored to $bin"
}

restore_rust() {
  local rustup_home="${RUSTUP_HOME:-$HOME/.rustup}" work t0 f
  rust_pin "${version:-}" || return 0
  if [[ -x "$rustup_home/toolchains/$rust_name/bin/rustc" ]] && "$rustup_home/toolchains/$rust_name/bin/rustc" --version >/dev/null 2>&1; then
    say "Rust $channel is installed"; return 0
  fi
  t0="$(date +%s)"
  work="$(mktemp -d)"; scratch+=("$work")
  r2 restore "$work/get" "$rust_key" >/dev/null 2>&1 || true
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

seed_archive() { # KIND VERSION
  local name key work
  name="$(archive_name "$1" "$2")"
  [[ -n "$(pin_of "$name")" ]] || { echo "toolchain-r2: no pin for $name" >&2; return 1; }
  key="$(archive_key "$name")"
  if key_held "$key"; then say "the cache already holds $key"; return 0; fi
  work="$(mktemp -d)"; scratch+=("$work")
  mkdir -p "$work/dir"
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 900 -o "$work/dir/$name" "$(upstream_url "$1" "$2")"
  [[ "$(sha256_of "$work/dir/$name")" == "$(pin_of "$name")" ]] \
    || { echo "::error::toolchain-r2: $name does not match scripts/ci/toolchain-archives.sha256" >&2; return 1; }
  r2 save "$work/dir" "$key"
}

seed_rust() {
  local work
  rust_pin "${version:-}" || return 1
  if key_held "$rust_key"; then say "the cache already holds $rust_key"; return 0; fi
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
  r2 save "$work/dir" "$rust_key"
}

if [[ "$mode" == restore ]]; then
  restore_one
  exit 0
fi

[[ -n "$url" ]] || { echo "toolchain-r2: seed needs TOOLCHAIN_R2_URL (the bucket's public URL)" >&2; exit 2; }
need_write
case "$kind" in
  node | bun) seed_archive "$kind" "$version" ;;
  rust) seed_rust ;;
  all)
    status=0
    while read -r _ name; do
      case "$name" in
        node-v*-linux-"$node_arch".tar.gz) v="${name#node-v}"; seed_archive node "${v%%-linux-*}" || status=1 ;;
        bun-v*-linux-"$bun_arch".zip) v="${name#bun-v}"; seed_archive bun "${v%%-linux-*}" || status=1 ;;
      esac
    done < <(grep -v '^#' "$pins")
    seed_rust || status=1
    exit "$status"
    ;;
esac
