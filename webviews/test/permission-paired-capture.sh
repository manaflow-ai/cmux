#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CMUX_BROWSER_TESTS=1
export PERMISSION_CAPTURE_BUNDLE=1
export PERMISSION_CAPTURE_DIR=/tmp/permission-paired/head
export PERMISSION_CAPTURE_LABEL=head
export EXPECT_CLAUDE_LABEL='Bypass permissions'
bun test test/permission-receipt-capture.test.ts -t "an ask in each harness"
tar -xf test/permission-capture-base.tar -C ..
bun scripts/pages/gen-strings.mjs --best-effort
export PERMISSION_CAPTURE_DIR=/tmp/permission-paired/base
export PERMISSION_CAPTURE_LABEL=base
export EXPECT_CLAUDE_LABEL='Full access'
bun test test/permission-receipt-capture.test.ts -t "an ask in each harness"
