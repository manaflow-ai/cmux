#!/usr/bin/env bash
# Build GNU bash 3.2.57, the release macOS /bin/bash is, so a Linux runner can
# parse scripts the way a Mac will (signing-keychain-macos.yml, bash32-syntax).
#
# Usage: scripts/ci/build-bash32.sh DEST
# Writes DEST/bin/bash. The tarball is pinned by SHA-256; a DEST that already
# holds a bash 3.2.57 (a cache hit) is kept.
set -euo pipefail

dest="${1:?usage: build-bash32.sh DEST}"
version="3.2.57"
sha256="3fa9daf85ebf35068f090ce51283ddeeb3c75eb5bc70b1a4a7cb05868bfe06a4"

if [[ -x "$dest/bin/bash" ]] && [[ "$("$dest/bin/bash" -c 'echo "$BASH_VERSION"')" == "$version"* ]]; then
  echo "bash $version already at $dest/bin/bash"
  exit 0
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bash32.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/bash-$version.tar.gz"
# Blacksmith runners time out connecting to the gnu.org hosts (2026-10-21), so
# the kernel.org and Berkeley GNU mirrors come first; the SHA-256 pin is the check.
for url in \
  "https://mirrors.kernel.org/gnu/bash/bash-$version.tar.gz" \
  "https://mirrors.ocf.berkeley.edu/gnu/bash/bash-$version.tar.gz" \
  "https://ftpmirror.gnu.org/bash/bash-$version.tar.gz" \
  "https://ftp.gnu.org/gnu/bash/bash-$version.tar.gz"; do
  if curl --proto '=https' --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
    --retry 3 --retry-delay 2 --output "$archive" "$url"; then
    break
  fi
  echo "::warning::could not download $url" >&2
done
[[ -s "$archive" ]] || { echo "::error::could not download bash $version" >&2; exit 1; }
got="$(sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive")"
[[ "${got%% *}" == "$sha256" ]] || { echo "::error::bash-$version.tar.gz SHA-256 is ${got%% *}, want $sha256" >&2; exit 1; }

tar -xzf "$archive" -C "$work"
cd "$work/bash-$version"
# 2008 C: K&R definitions, implicit declarations and tentative definitions that
# a current GCC rejects by default. Only the parser matters here, so no
# readline, history or bash malloc.
CFLAGS="-O2 -std=gnu89 -fcommon -w" ./configure --quiet --prefix="$dest" \
  --without-bash-malloc --disable-readline --disable-history >/dev/null
make -s -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" bash >/dev/null
mkdir -p "$dest/bin"
cp bash "$dest/bin/bash"
"$dest/bin/bash" -c 'echo "built bash $BASH_VERSION"'
