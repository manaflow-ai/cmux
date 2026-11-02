#!/usr/bin/env bash
# Puts a release signer binary built by build.sh (a job artifact) in place and
# checks it against the sha256 the build job printed.
#
#   scripts/ci/release-signer/install.sh <binary> <sha256> >> "$GITHUB_ENV"
#
# Installs the binary mode 755 and prints CMUX_SIGNER=<path> on stdout;
# everything else goes to stderr, so stdout can be appended to $GITHUB_ENV.
# It refuses a binary whose digest is not the expected one, or that does not
# run. The variable it prints never starts with RCODESIGN_: the signer reads
# every RCODESIGN_* environment variable as its own configuration. Not used
# by any workflow yet.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <binary> <sha256>" >&2; exit 2; }
bin="$1" want="$2"
[[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "error: expected sha256 '$want' is not 64 hex digits" >&2; exit 1; }
[[ -f "$bin" ]] || { echo "error: signer binary not found at $bin" >&2; exit 1; }
if command -v sha256sum >/dev/null; then got="$(sha256sum "$bin" | cut -d' ' -f1)"; else got="$(shasum -a 256 "$bin" | cut -d' ' -f1)"; fi
[[ "$got" == "$want" ]] || { echo "error: signer binary sha256 $got is not the expected $want" >&2; exit 1; }
chmod 755 "$bin"
bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"
# shellcheck source=signer-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/signer-env.sh"
run_signer "$bin" --version >&2 || { echo "error: signer binary does not run" >&2; exit 1; }
echo "CMUX_SIGNER=$bin"
