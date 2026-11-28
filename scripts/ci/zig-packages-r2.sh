#!/usr/bin/env bash
# zig-packages-r2.sh restore CACHE_DIR | seed WORK_DIR
#
# The Zig package archives scripts/ci/zig-packages.lock mirrors (<hash>.tar.gz on the ghostty-next
# zig-packages GitHub release), also kept in the CI cache bucket (r2-cache.sh), so a build whose
# release downloads GitHub refuses still gets every package without leaving hosts we control.
#
# Why: nightly run 45776501690 (job 139764481921, Mac cmux15 with a cold ~/.cache/zig) failed at
# "Build the cmux-next source archive": every one of the 40 mirror downloads failed while the run's
# GitHub token had 0 of its 5000 REST calls left and setup-bun's github.com download got a 403, and
# mirror-only Zig then refused each package (no ship without the Ghostty license tree).
#
# restore: unpack the bucket's copy into a scratch directory and move each archive the cache lacks into
#   CACHE_DIR/p/<hash>.tar.gz, only when its sha256 is the one the lock pins (Zig checks the package hash
#   again when it unpacks). Every error is a miss and exits 0. seed-zig-package-archives.sh runs it when
#   its mirror round left packages missing.
# seed: when the bucket has no copy of this lock, download every locked package from the mirror (each
#   checked against its sha256) into WORK_DIR and save it with the bucket's write credentials.
#
# The key is the hash of zig-packages.lock, so a new package moves it. ZIG_PACKAGES_R2_URL is the
# bucket's public URL (default https://ci-cache-next.cmux.com under GitHub Actions; empty turns it off).
# The archives are the same on every OS and architecture: one namespace, `any`.
set -euo pipefail

mode="${1:-}"
dir="${2:-}"
if [[ "$mode" != restore && "$mode" != seed ]] || [[ -z "$dir" ]]; then
  echo "usage: zig-packages-r2.sh restore CACHE_DIR | seed WORK_DIR" >&2
  exit 2
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
r2_cache="$here/r2-cache.sh"
lock="${CMUX_ZIG_LOCK:-$here/zig-packages.lock}"
url="${ZIG_PACKAGES_R2_URL-}"
if [[ -z "${ZIG_PACKAGES_R2_URL+set}" && "${GITHUB_ACTIONS:-}" == true ]]; then
  url=https://ci-cache-next.cmux.com
fi
[[ -n "$url" ]] || { echo "zig-packages-r2: no cache URL; nothing to $mode"; exit 0; }
[[ -f "$lock" ]] || { echo "zig-packages-r2: no lock at $lock; nothing to $mode"; exit 0; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | cut -d' ' -f1
  else shasum -a 256 < "$1" | cut -d' ' -f1; fi
}
key="zig-packages-v1-$(sha256_of "$lock" | cut -c1-16)"
r2() { CI_CACHE_R2_PUBLIC_URL="$url" CI_CACHE_R2_NAMESPACE=any GITHUB_OUTPUT='' bash "$r2_cache" "$@"; }
# One "hash sha256" line per locked package.
packages() { awk '$1 != "mirror" && $1 !~ /^#/ && NF >= 2 { print $1, $2 }' "$lock"; }

if [[ "$mode" == restore ]]; then
  mkdir -p "$dir/p" 2>/dev/null || { echo "zig-packages-r2: cannot write $dir/p; a miss"; exit 0; }
  missing=0
  while read -r hash _sha; do
    [[ -e "$dir/p/$hash.tar.gz" || -e "$dir/p/$hash" ]] || missing=$((missing + 1))
  done < <(packages)
  (( missing > 0 )) || { echo "zig-packages-r2: $dir/p already holds every locked package"; exit 0; }
  work="$(mktemp -d "${TMPDIR:-/tmp}/zig-packages-r2.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  t0=$SECONDS
  out="$(r2 restore "$work/copy" "$key" 2>&1)" || true
  put=0
  while read -r hash sha; do
    [[ -e "$dir/p/$hash.tar.gz" || -e "$dir/p/$hash" ]] && continue
    copy="$work/copy/$hash.tar.gz"
    [[ -f "$copy" && ! -L "$copy" ]] || continue
    [[ "$(sha256_of "$copy")" == "$sha" ]] || { echo "zig-packages-r2: $hash in the bucket is not the locked sha256; skipped" >&2; continue; }
    mv -f "$copy" "$dir/p/.r2-$hash-$$" && mv -f "$dir/p/.r2-$hash-$$" "$dir/p/$hash.tar.gz" && put=$((put + 1))
  done < <(packages)
  if [[ ! -d "$work/copy" ]]; then
    echo "zig-packages-r2: no cached $key ($(tail -1 <<<"$out")); $missing package(s) left to the mirror"
  else
    echo "zig-packages-r2: put $put of $missing missing package(s) from $key in $((SECONDS - t0)) s (no github.com)"
  fi
  exit 0
fi

for extension in tar.zst tar.gz; do
  if curl --fail --silent --head --location --connect-timeout 15 --max-time 60 \
      "${url%/}/v1/any/objects/$key.$extension" >/dev/null; then
    echo "zig-packages-r2: the cache already holds $key.$extension"
    exit 0
  fi
done
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET; do
  [[ -n "${!var:-}" ]] || { echo "zig-packages-r2: seed needs $var (the bucket's write credentials)" >&2; exit 2; }
done
mirror="$(awk '$1 == "mirror" { print $2; exit }' "$lock")"
[[ -n "$mirror" ]] || { echo "zig-packages-r2: the lock names no mirror" >&2; exit 1; }
mkdir -p "$dir/p"
failed=0
while read -r hash sha; do
  bash "$here/seed-zig-package-archives.sh" --one "$dir" "$hash" "$mirror$hash.tar.gz" "$sha" || failed=$((failed + 1))
done < <(packages)
(( failed == 0 )) || { echo "::error::$failed locked package(s) could not be downloaded from $mirror; nothing saved" >&2; exit 1; }
r2 save "$dir/p" "$key"
