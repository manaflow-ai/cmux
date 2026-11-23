#!/usr/bin/env bash
# Install the repository-pinned cargo-nextest and print the directory that holds it.
#
# cargo nextest is cmux-tui's test runner: scripts/ci/cmux-tui-rust-check.sh's test mode, the
# `--profile ci` profile in cmux-tui/.config/nextest.toml, and the testbox warmup all run it. This
# is the one pinned, checksummed install every caller shares, so there is a single version to bump:
#   dir="$(bash scripts/ci/install-nextest.sh)" && export PATH="$dir:$PATH"
# CMUX_NEXTEST_TOOLS_ROOT puts the install somewhere other than <repo>/.build/tools (fast checks
# points it at the sticky cache disk, so a host downloads the tarball once).
# --print-version prints the pin and installs nothing.
set -euo pipefail

version=0.9.148

if [[ "${1:-}" == --print-version ]]; then
  echo "$version"
  exit 0
fi
if [[ $# -gt 0 ]]; then
  echo "usage: install-nextest.sh [--print-version]" >&2
  exit 2
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-*) asset=universal-apple-darwin sha=6c23b7fb4ca82c571fc8dfedbab45bfa773d45918f933170c85d21cd7f4b852b ;;
  Linux-x86_64) asset=x86_64-unknown-linux-gnu sha=223ba936714cc861a9cdedad5a8eb664dfdd69d6fbdf6cea6aa8184f523290dc ;;
  # The arm64 Linux VMs on the fleet Macs (Lima, cmux-ci workers) take Linux steps too.
  Linux-aarch64) asset=aarch64-unknown-linux-gnu sha=81469eb963ef883fd590e60189e77d6aba3d91b418591d3391f50fe3e9480d2b ;;
  *) echo "error: no pinned cargo-nextest for $(uname -sm)" >&2; exit 3 ;;
esac

tools_root="${CMUX_NEXTEST_TOOLS_ROOT:-}"
if [[ -z "$tools_root" ]]; then
  tools_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)/.build/tools"
fi
dir="$tools_root/cargo-nextest-$version"

if [[ ! -x "$dir/cargo-nextest" ]]; then
  mkdir -p "$dir"
  archive="$dir/cargo-nextest.tar.gz"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 120 --output "$archive" \
    "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$version/cargo-nextest-$version-$asset.tar.gz" \
    || { echo "error: cargo-nextest $version download failed" >&2; exit 3; }
  if command -v sha256sum >/dev/null; then sum="$(sha256sum "$archive")"; else sum="$(shasum -a 256 "$archive")"; fi
  if [[ "${sum%% *}" != "$sha" ]]; then
    rm -f "$archive"
    echo "error: cargo-nextest archive sha256 ${sum%% *} is not the pinned $sha" >&2
    exit 3
  fi
  # extract beside it and rename, so a broken extract never looks installed
  rm -rf "$dir/x" && mkdir -p "$dir/x" && tar -xzf "$archive" -C "$dir/x" cargo-nextest && mv "$dir/x/cargo-nextest" "$dir/cargo-nextest" \
    || { rm -rf "$dir/x" "$archive"; echo "error: cargo-nextest archive did not extract" >&2; exit 3; }
  rm -rf "$dir/x" "$archive"
fi

echo "$dir"
