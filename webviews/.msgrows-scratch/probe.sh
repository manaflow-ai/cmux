#!/usr/bin/env bash
cd "$(dirname "$0")/.."
bunx tsc -p . --noEmit 2>&1 | tail -20; echo "== tsc exit ${PIPESTATUS[0]}"
PROBE=1 OUT="${FAST_CHECKS_OUT:-/tmp/x}/probe" SCENES=agent-pane.message-line-look:leo-capture:dark bun .msgrows-scratch/capture.ts 2>&1 | grep -E "PROBE|FAIL|noready"
PROBE=1 W=520 OUT="${FAST_CHECKS_OUT:-/tmp/x}/probe520" SCENES=agent-pane.message-line-look:leo-capture:dark bun .msgrows-scratch/capture.ts 2>&1 | grep -E "PROBE|FAIL|noready"
