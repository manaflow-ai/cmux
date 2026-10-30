#!/usr/bin/env bash
# Development-only Cloud end to end (plans/cmux-next/cloud-automation.md 24): create a machine
# through the dev API, bind, link token, pause, start, delete. Refuses any non-dev origin.
# Usage: scripts/cmux-next/cloud-dev-e2e.sh --out-dir <dir> [--keep]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root/web"
[ -d node_modules ] || bun install --frozen-lockfile --ignore-scripts
exec bun scripts/cmux-vm-image/dev-e2e.ts "$@"
