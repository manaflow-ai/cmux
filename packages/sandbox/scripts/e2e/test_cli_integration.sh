#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
CLI_SCRIPT="${ROOT_DIR}/packages/sandbox/scripts/cmux-cli.sh"
CONTAINER_NAME="${CONTAINER_NAME:-cmux-sandbox-dev-run}"

echo "Stopping any existing container to test auto-start..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Running 'cmux-cli.sh sandboxes list' (should trigger server start)..."
# This might take a moment to start the server
OUTPUT=$("${CLI_SCRIPT}" sandboxes list)
echo "${OUTPUT}"

if echo "${OUTPUT}" | grep -q "\["; then
  echo "SUCCESS: Server started and returned JSON list."
else
  echo "FAILURE: Did not get expected JSON output."
  exit 1
fi

echo "Running 'cmux-cli.sh new' (non-interactive mode for test)..."
# We use 'new' but we can't easily test the interactive shell in this script without expect/pty.
# Instead, let's create a sandbox explicitly and then exec into it.
CREATE_OUTPUT=$("${CLI_SCRIPT}" sandboxes create --name "cli-test-sandbox")
echo "${CREATE_OUTPUT}"

ID=$(echo "${CREATE_OUTPUT}" | grep -o '"id": "[^"]*"' | cut -d'"' -f4)
echo "Created Sandbox ID: ${ID}"

if [ -z "${ID}" ]; then
  echo "Failed to parse Sandbox ID."
  exit 1
fi

echo "Exec 'echo hello' inside sandbox..."
EXEC_OUTPUT=$("${CLI_SCRIPT}" sandboxes exec "${ID}" echo hello)
echo "${EXEC_OUTPUT}"

if echo "${EXEC_OUTPUT}" | grep -q "hello"; then
  echo "SUCCESS: 'hello' echoed back."
else
  echo "FAILURE: Could not execute command."
  exit 1
fi

echo "Cleaning up..."
"${CLI_SCRIPT}" sandboxes delete "${ID}" >/dev/null
