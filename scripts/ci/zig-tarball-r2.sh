#!/usr/bin/env bash
# zig-tarball-r2.sh restore|seed DIR
#
# The verified Zig tarballs install-zig-ci.sh reads from ZIG_TARBALL_CACHE_DIR, kept in the CI cache
# bucket (r2-cache.sh) so a fresh runner never depends on the third-party Zig mirrors.
#
# Why: the actions/cache entry `cmux-zig-tarball-*` is only ever saved by a runner that downloaded
# Zig. The owned Linux fleet keeps Zig installed (install-zig-ci.sh reuses it and downloads nothing),
# so the entry stays empty and every Freestyle runner downloads Zig cold. On 2026-11-23 job
# 137551791655 (cmux_next_ daemon tests, runner fsr-1795418472-c6cfb8-j5) spent its whole 480 s
# budget on four mirrors (two 502s, two stalls) and failed before cargo ran.
#
# restore: when DIR holds no tarball, restore the bucket's copy into DIR. Every error is a miss; the
#   installer still checks each tarball against scripts/ci/zig-tarballs.sha256, so a bad copy is
#   discarded, never used.
# seed: when the bucket has no copy, download through install-zig-ci.sh (a job-local install, a
#   longer budget) into DIR and save DIR with the bucket's write credentials (r2-cache.sh save). It also
#   saves the installed, std-fixed tree under install-zig-ci.sh's zig_tree_key, which that script restores
#   before it downloads (no .tar.xz unpack, no std fix on the reader).
#
# The key is the hash of zig-tarballs.sha256: a new reviewed Zig version moves it, as it moves the
# actions/cache key. ZIG_TARBALL_R2_URL is the bucket's public URL (default
# https://ci-cache-next.cmux.com under GitHub Actions; empty turns it off).
set -euo pipefail

mode="${1:-}"
dir="${2:-}"
if [[ "$mode" != restore && "$mode" != seed ]] || [[ -z "$dir" ]]; then
  echo "usage: zig-tarball-r2.sh restore|seed DIR" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
r2_cache="$root/scripts/ci/r2-cache.sh"
url="${ZIG_TARBALL_R2_URL-}"
if [[ -z "${ZIG_TARBALL_R2_URL+set}" && "${GITHUB_ACTIONS:-}" == true ]]; then
  url=https://ci-cache-next.cmux.com
fi
pins="$root/scripts/ci/zig-tarballs.sha256"
if command -v sha256sum >/dev/null 2>&1; then
  pins_hash="$(sha256sum "$pins" | cut -c1-16)"
else
  pins_hash="$(shasum -a 256 "$pins" | cut -c1-16)"
fi
key="zig-tarballs-v1-$pins_hash"
namespace="${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}"

has_tarball() { compgen -G "$dir/*.tar.xz" >/dev/null; }

if [[ -z "$url" ]]; then
  echo "zig-tarball-r2: no cache URL; nothing to $mode"
  exit 0
fi

if [[ "$mode" == restore ]]; then
  if has_tarball; then
    echo "zig-tarball-r2: $dir already holds a tarball"
    exit 0
  fi
  t0="$(date +%s)"
  out="$(CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$namespace" GITHUB_OUTPUT='' \
    bash "$r2_cache" restore "$dir" "$key" 2>&1)" || true
  if has_tarball; then
    echo "zig-tarball-r2: restored $key in $(( $(date +%s) - t0 )) s"
  else
    echo "zig-tarball-r2: no cached $key ($(tail -1 <<<"$out")); install-zig-ci.sh downloads it"
  fi
  exit 0
fi

key_held() { # KEY
  local extension
  for extension in tar.zst tar.gz; do
    curl --fail --silent --head --location --connect-timeout 15 --max-time 60 \
      "${url%/}/v1/$namespace/objects/$1.$extension" >/dev/null && return 0
  done
  return 1
}
# The unpacked, std-fixed tree install-zig-ci.sh restores before it downloads (its zig_tree_key); empty when
# the version has no pinned tarball (no key, nothing to seed).
tree_key="$(ZIG_PRINT_TREE_KEY=1 ZIG_FORCE_LOCAL_INSTALL=1 bash "$root/scripts/install-zig-ci.sh" 2>/dev/null || true)"
tarball_held=0 tree_held=1
key_held "$key" && tarball_held=1 && echo "zig-tarball-r2: the cache already holds $key"
if [[ -n "$tree_key" ]]; then
  tree_held=0
  key_held "$tree_key" && tree_held=1 && echo "zig-tarball-r2: the cache already holds $tree_key"
fi
[[ "$tarball_held" == 1 && "$tree_held" == 1 ]] && exit 0
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET; do
  [[ -n "${!var:-}" ]] || { echo "zig-tarball-r2: seed needs $var (the bucket's write credentials)" >&2; exit 2; }
done
mkdir -p "$dir"
# A held tarball comes from the bucket, so seeding the tree alone downloads nothing from the Zig mirrors.
[[ "$tarball_held" == 0 ]] || bash "$0" restore "$dir"
tree_root="$(mktemp -d)"
trap 'rm -rf "$tree_root"' EXIT
ZIG_FORCE_LOCAL_INSTALL=1 ZIG_TARBALL_CACHE_DIR="$dir" ZIG_INSTALL_ROOT="$tree_root" ZIG_TREE_R2_URL='' \
  ZIG_DOWNLOAD_BUDGET_SECONDS="${ZIG_DOWNLOAD_BUDGET_SECONDS:-600}" ZIG_DOWNLOAD_ATTEMPTS="${ZIG_DOWNLOAD_ATTEMPTS:-4}" \
  bash "$root/scripts/install-zig-ci.sh"
if [[ "$tarball_held" == 0 ]]; then
  has_tarball || { echo "::error::install-zig-ci.sh left no tarball in $dir; nothing saved" >&2; exit 1; }
  CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$namespace" GITHUB_OUTPUT='' \
    bash "$r2_cache" save "$dir" "$key"
fi
if [[ "$tree_held" == 0 ]]; then
  compgen -G "$tree_root/zig-*/zig" >/dev/null || { echo "::error::install-zig-ci.sh left no zig tree in $tree_root; nothing saved" >&2; exit 1; }
  CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$namespace" GITHUB_OUTPUT='' \
    bash "$r2_cache" save "$tree_root" "$tree_key"
fi
