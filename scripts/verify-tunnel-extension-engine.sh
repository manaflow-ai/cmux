#!/usr/bin/env bash
# Verify that a Cloud tunnel extension binary (or a libwg-go.a archive) carries
# the real wireguard-go engine rather than the stub scripts/build-wireguard-go.sh
# emits when Go is missing at build time.
#
# Usage: scripts/verify-tunnel-extension-engine.sh <mach-o binary or archive>
#
# Two facts, both required, and both survive `strip -S -x` and dead-code
# stripping: Go-compiled code carries a `__go_buildinfo` section (the stub is
# plain C and has none), and the WireGuard entry point `wgTurnOn` is an exported
# symbol. A stub-marker symbol alone would not do: an unreferenced global can be
# dead-stripped from a Release link, and a missing marker must never read as
# "real engine".
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <cmuxTunnel binary or libwg-go.a>" >&2
  exit 2
fi
BINARY="$1"
[[ -f "$BINARY" ]] || { echo "error: missing tunnel engine binary at $BINARY" >&2; exit 1; }

OTOOL="${CMUX_OTOOL:-otool}"
NM="${CMUX_NM:-nm}"

if ! "$OTOOL" -l "$BINARY" 2>/dev/null | grep -q "__go_buildinfo"; then
  echo "error: $BINARY has no Go build info section; it was built with the stub WireGuard bridge (Go missing at build time) and cannot carry traffic" >&2
  exit 1
fi
if ! "$NM" "$BINARY" 2>/dev/null | grep -qE " T _?wgTurnOn$"; then
  echo "error: $BINARY does not export wgTurnOn; the WireGuard bridge is missing" >&2
  exit 1
fi
echo "tunnel engine OK: $BINARY"
