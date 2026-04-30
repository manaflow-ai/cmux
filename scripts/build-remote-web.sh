#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../remote-web"
bun install --frozen-lockfile
bun run build
