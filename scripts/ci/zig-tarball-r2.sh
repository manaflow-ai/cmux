#!/usr/bin/env bash
# zig-tarball-r2.sh fetch NAME DIR | restore DIR | seed
#
# Every Zig tarball pinned in scripts/ci/zig-tarballs.sha256, kept in the CI cache bucket (r2-cache.sh)
# for every platform, so no runner depends on the third-party Zig mirrors. install-zig-ci.sh reads the
# bucket first, before the mirrors.
#
# Why: the mirrors and ziglang.org are slow or down often enough to fail jobs. On 2026-11-23 job
# 137551791655 (a fresh Freestyle runner) spent its whole 480 s budget on four mirrors (two 502s, two
# stalls). On 2026-11-24 the NIGHTLY signer's job 138863767001 (run 45512239356) did the same: all four
# sources ran at 100-400 KB/s, and the nightly sat unbuilt. The first bucket copy held only the
# seeder's own platform (Linux x64): the seeder installed Zig for its host and saved that, so a Mac or an
# arm64 runner always missed. Now the seeder saves every pinned tarball under its own platform.
#
# fetch NAME DIR: restore the bucket's copy of NAME (e.g. zig-aarch64-macos-0.17.0) into DIR, a
#   directory of its own that this replaces. Every error is a miss, exit 0; the caller checks the
#   tarball against the pin either way.
# restore DIR: fetch every pinned tarball of this runner's platform that DIR lacks (an actions/cache
#   directory install-zig-ci.sh reads as ZIG_TARBALL_CACHE_DIR).
# seed: for each pinned tarball the bucket lacks, download it (and its .minisig), check the pin and
#   save it with the bucket's write credentials (r2-cache.sh save). A key the bucket holds costs one
#   HEAD request. It also saves this runner's installed, std-fixed tree under install-zig-ci.sh's
#   zig_tree_key, which that script restores before it downloads (no .tar.xz unpack, no std fix on the
#   reader); the tree runs only on its own platform, so it is the seeder's platform alone.
#
# The key holds the tarball's pinned SHA-256: a new or changed pin is a new key. ZIG_TARBALL_R2_URL is
# the bucket's public URL (default https://ci-cache-next.cmux.com under GitHub Actions; empty turns
# it off).
set -euo pipefail

usage() { echo "usage: zig-tarball-r2.sh fetch NAME DIR | restore DIR | seed" >&2; exit 2; }
mode="${1:-}"
case "$mode" in
  fetch) [[ -n "${2:-}" && -n "${3:-}" ]] || usage ;;
  restore) [[ -n "${2:-}" ]] || usage ;;
  seed) ;;
  *) usage ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
r2_cache="$root/scripts/ci/r2-cache.sh"
pins="$root/scripts/ci/zig-tarballs.sha256"
url="${ZIG_TARBALL_R2_URL-}"
if [[ -z "${ZIG_TARBALL_R2_URL+set}" && "${GITHUB_ACTIONS:-}" == true ]]; then
  url=https://ci-cache-next.cmux.com
fi
if [[ -z "$url" ]]; then
  echo "zig-tarball-r2: no cache URL; nothing to $mode"
  exit 0
fi

pin_of() { awk -v name="$1.tar.xz" '$1 !~ /^#/ && $2 == name { print $1; exit }' "$pins"; }
pinned_names() { awk '$1 !~ /^#/ && NF == 2 { sub(/\.tar\.xz$/, "", $2); print $2 }' "$pins"; }
# The r2-cache namespace (RUNNER_OS-RUNNER_ARCH) of a tarball name, zig-<arch>-<os>-<version>.
namespace_of() {
  local rest="${1#zig-}" arch os
  arch="${rest%%-*}"; rest="${rest#*-}"; os="${rest%%-*}"
  case "$os" in macos) os=macOS ;; linux) os=Linux ;; *) return 1 ;; esac
  case "$arch" in aarch64) arch=ARM64 ;; x86_64) arch=X64 ;; *) return 1 ;; esac
  printf '%s-%s\n' "$os" "$arch"
}
key_of() { printf 'zig-tarball-v2-%s-%s\n' "$1" "$(cut -c1-16 <<<"$2")"; }
host_namespace() {
  local os="${RUNNER_OS:-$(uname -s)}" arch="${RUNNER_ARCH:-$(uname -m)}"
  case "$os" in Darwin) os=macOS ;; esac
  case "$arch" in arm64 | aarch64) arch=ARM64 ;; x86_64) arch=X64 ;; esac
  printf '%s-%s\n' "$os" "$arch"
}

fetch() { # NAME DIR
  local name="$1" dir="$2" sha ns key t0 out
  sha="$(pin_of "$name")"
  [[ -n "$sha" ]] || { echo "zig-tarball-r2: $name has no pin; nothing to fetch"; return 0; }
  ns="$(namespace_of "$name")" || { echo "zig-tarball-r2: no platform for $name"; return 0; }
  key="$(key_of "$name" "$sha")"
  t0="$(date +%s)"
  out="$(CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$ns" GITHUB_OUTPUT='' \
    bash "$r2_cache" restore "$dir" "$key" 2>&1)" || true
  if [[ -f "$dir/$name.tar.xz" ]]; then
    echo "zig-tarball-r2: restored $key in $(( $(date +%s) - t0 )) s"
  else
    echo "zig-tarball-r2: no cached $key ($(tail -1 <<<"$out"))"
  fi
}

if [[ "$mode" == fetch ]]; then
  fetch "$2" "$3"
  exit 0
fi

if [[ "$mode" == restore ]]; then
  dir="$2" ns="$(host_namespace)"
  mkdir -p "$dir"
  while read -r name; do
    [[ "$(namespace_of "$name" || true)" == "$ns" && ! -f "$dir/$name.tar.xz" ]] || continue
    work="$(mktemp -d)"
    fetch "$name" "$work/t"
    if [[ -f "$work/t/$name.tar.xz" ]]; then
      for file in "$work/t/$name.tar.xz" "$work/t/$name.tar.xz.minisig"; do
        [[ -f "$file" ]] && mv -f "$file" "$dir/"
      done
    fi
    rm -rf "$work"
  done < <(pinned_names)
  exit 0
fi

# seed
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
download() { # URL OUT: the first source that answers whole, 10 min each
  local source
  for source in "https://zig-mirror.tsimnet.eu/zig" "https://zigmirror.hryx.net/zig" "https://pkg.hexops.org/zig" "https://ziglang.org/download/$version"; do
    if curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 --max-time 600 \
        -o "$2" "$source/$1"; then
      return 0
    fi
    echo "zig-tarball-r2: $source/$1 failed; trying the next source" >&2
  done
  return 1
}
missing=0 seeded=0 failed=0
while read -r name; do
  sha="$(pin_of "$name")"
  ns="$(namespace_of "$name")" || continue
  key="$(key_of "$name" "$sha")"
  held=0
  for extension in tar.zst tar.gz; do
    if curl --fail --silent --head --location --connect-timeout 15 --max-time 60 \
        "${url%/}/v1/$ns/objects/$key.$extension" >/dev/null; then
      held=1
      break
    fi
  done
  if [[ "$held" == 1 ]]; then
    echo "zig-tarball-r2: the cache already holds $ns/$key"
    continue
  fi
  missing=$((missing + 1))
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET; do
    [[ -n "${!var:-}" ]] || { echo "zig-tarball-r2: seed needs $var (the bucket's write credentials)" >&2; exit 2; }
  done
  version="${name##*-}"
  work="$(mktemp -d)"
  mkdir -p "$work/t"
  if download "$name.tar.xz" "$work/t/$name.tar.xz" && [[ "$(sha256_of "$work/t/$name.tar.xz")" == "$sha" ]]; then
    # The signature is optional: install-zig-ci.sh checks it when minisign is installed, and downloads
    # it then if the bucket has none.
    download "$name.tar.xz.minisig" "$work/t/$name.tar.xz.minisig" 2>/dev/null || rm -f "$work/t/$name.tar.xz.minisig"
    # r2-cache.sh save exits 0 on a failed upload (it never reds a seed job); its last line says which.
    saved="$(CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$ns" GITHUB_OUTPUT='' \
      bash "$r2_cache" save "$work/t" "$key" 2>&1)" || true
    printf '%s\n' "$saved"
    if grep -qE "^r2-cache: (saved $key|$key already exists)" <<<"$saved"; then
      seeded=$((seeded + 1))
      echo "zig-tarball-r2: saved $ns/$key"
    else
      failed=$((failed + 1))
    fi
  else
    echo "::warning::zig-tarball-r2: could not download $name with its pinned SHA-256; not saved" >&2
    failed=$((failed + 1))
  fi
  rm -rf "$work"
done < <(pinned_names)
echo "zig-tarball-r2: $missing missing, $seeded saved, $failed failed"

# The unpacked, std-fixed tree of this runner's Zig, which install-zig-ci.sh restores before it downloads
# (its zig_tree_key, under its RUNNER_OS-RUNNER_ARCH namespace); empty when the version has no pinned
# tarball (no key, nothing to seed). Its tarball comes from the bucket (restore, just seeded above), so
# seeding the tree downloads nothing from the Zig mirrors.
tree_key="$(ZIG_PRINT_TREE_KEY=1 ZIG_FORCE_LOCAL_INSTALL=1 bash "$root/scripts/install-zig-ci.sh" 2>/dev/null || true)"
if [[ -n "$tree_key" ]]; then
  ns="$(host_namespace)" held=0
  for extension in tar.zst tar.gz; do
    if curl --fail --silent --head --location --connect-timeout 15 --max-time 60 \
        "${url%/}/v1/$ns/objects/$tree_key.$extension" >/dev/null; then
      held=1
      break
    fi
  done
  if [[ "$held" == 1 ]]; then
    echo "zig-tarball-r2: the cache already holds $ns/$tree_key"
  else
    for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET; do
      [[ -n "${!var:-}" ]] || { echo "zig-tarball-r2: seed needs $var (the bucket's write credentials)" >&2; exit 2; }
    done
    work="$(mktemp -d)"
    bash "$0" restore "$work/tarballs"
    if ZIG_FORCE_LOCAL_INSTALL=1 ZIG_TARBALL_CACHE_DIR="$work/tarballs" ZIG_INSTALL_ROOT="$work/tree" ZIG_TREE_R2_URL='' \
        ZIG_DOWNLOAD_BUDGET_SECONDS="${ZIG_DOWNLOAD_BUDGET_SECONDS:-600}" ZIG_DOWNLOAD_ATTEMPTS="${ZIG_DOWNLOAD_ATTEMPTS:-4}" \
        bash "$root/scripts/install-zig-ci.sh" && compgen -G "$work/tree/zig-*/zig" >/dev/null; then
      CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE="$ns" GITHUB_OUTPUT='' \
        bash "$r2_cache" save "$work/tree" "$tree_key"
    else
      echo "::error::install-zig-ci.sh left no zig tree; $ns/$tree_key not saved" >&2
      failed=$((failed + 1))
    fi
    rm -rf "$work"
  fi
fi
(( failed == 0 ))
