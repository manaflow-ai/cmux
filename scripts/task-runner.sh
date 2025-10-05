#!/usr/bin/env bash
set -euo pipefail

# cmux task runner helper
# Usage examples:
#   ./scripts/task-runner.sh start --environment <envId> --prompt "Describe the task"
#   ./scripts/task-runner.sh exec --instance <instanceId> --command "bash -lc 'ls /root'"
# The script wraps the Bun CLI in apps/www/scripts/task-runner-cli.ts and ensures the
# correct .env file is loaded so agents and Morph calls authenticate properly. All
# additional arguments are forwarded directly to the underlying CLI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${ROOT_DIR}"

bun run --env-file ./.env apps/www/scripts/task-runner-cli.ts "$@"
