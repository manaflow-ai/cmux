#!/usr/bin/env bash
# Let XCTest drive the app host without an authentication prompt. Shared by
# the app-host unit-test shards and compile admission's changed-suites run.
set -euo pipefail
if ! command -v automationmodetool >/dev/null 2>&1; then
  echo "::warning::automationmodetool is unavailable; XCTest will use its default automation-mode setup"
  exit 0
fi
if sudo -n true 2>/dev/null; then
  sudo -n automationmodetool enable-automationmode-without-authentication
else
  echo "::warning::Passwordless sudo unavailable; XCTest will use its default automation-mode setup"
fi
