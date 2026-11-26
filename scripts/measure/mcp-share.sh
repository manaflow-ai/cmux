#!/usr/bin/env bash
# Shared user MCP servers (acpmux's ACPMUX_MCP_SHARE pool) against one server per chat, on a fleet host:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/mcp-share.sh --ref SHA \
#     [--os macos|linux] [--arg=counts=5,20] --timeout 3600
# Builds this ref's acpmux, then scripts/measure/mcp-share.py opens N chats' MCP handshakes at once against
# the filesystem server (npx @modelcontextprotocol/server-filesystem), each on its own server (off), through
# one isolated daemon's pool (on), and N more while that server runs (warm). No harness, no credential.
set -euo pipefail
counts=5,20
for arg in "$@"; do
  case "$arg" in
    counts=*) counts="${arg#counts=}" ;;
    *) echo "mcp-share.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$counts" =~ ^[0-9]{1,3}(,[0-9]{1,3})*$ ]] || { echo "mcp-share.sh: counts=5,20" >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
work="$(mktemp -d "${TMPDIR:-/tmp}/mcp-share.XXXXXX")"
trap 'rm -rf "$work"' EXIT
scripts/cmux-next/build-acpmux.sh --output "$work/acpmux"
command -v npx >/dev/null || { echo "MCP-SHARE-ERR no npx on this host"; exit 1; }
mkdir -p "$work/files"
npx -y @modelcontextprotocol/server-filesystem "$work/files" </dev/null >/dev/null 2>&1 || true
echo "MCP-SHARE-HOST $(uname -sm) cpus=$(getconf _NPROCESSORS_ONLN) node=$(node --version)"
python3 -I scripts/measure/mcp-share.py --acpmux "$work/acpmux" --counts "$counts" \
  --server "npx -y @modelcontextprotocol/server-filesystem $work/files" --marker "server-filesystem"
