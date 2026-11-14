#!/bin/bash
# cua-driver-direct.sh: the baseline binary, unmodified, with `mcp --direct` on macOS: the
# release tarball has no CuaDriver.app for its default proxy mode, so the MCP process owns
# the runtime itself (TCC grants are on the guest's launchd job and the binary).
B="$HOME/cu/evals/computer-use/.cache/cua-driver-0.38.0/macos-arm64/cua-driver"
if [[ $1 == mcp ]]; then shift; exec "$B" mcp --direct "$@"; fi
exec "$B" "$@"
