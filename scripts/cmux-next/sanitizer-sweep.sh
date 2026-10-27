#!/usr/bin/env bash
# The CmuxNext closure's Swift package tests under TSan, ASan, UBSan and the strict
# cooperative pool, after a base pass that lists the suites already red without a
# sanitizer (scripts/cmux-next/README-sanitizers.md). A fleet step only:
#   cmux-ci run --class isolated --ref SHA --script scripts/cmux-next/sanitizer-sweep.sh -- \
#     --sanitize thread,address,undefined,coop-strict --out .build/sanitizer-sweep/findings.jsonl
set -euo pipefail
exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/sanitizer_sweep.py" "$@"
