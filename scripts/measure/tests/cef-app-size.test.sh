#!/usr/bin/env bash
# Contract test for the paired CEF measurement: payload size is recorded before
# signing, and a signing failure cannot discard the comparison report.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cef-app-size.sh"
pre_sign_line="$(grep -n 'du -sk' "$script" | head -1 | cut -d: -f1)"
sign_line="$(grep -n 'codesign --force --deep --sign - --timestamp=none' "$script" | head -1 | cut -d: -f1)"
report_line="$(grep -n "comparison.json" "$script" | tail -1 | cut -d: -f1)"

[[ -n "$pre_sign_line" && -n "$sign_line" && -n "$report_line" ]]
(( pre_sign_line < sign_line ))
(( sign_line < report_line ))
grep -q 'pre-sign-du.tsv' "$script"
grep -q 'signing_status=1' "$script"
grep -q "launch_and_browser_smoke_passed.*smoke_baseline=passed" "$script"
grep -q 'final_status=' "$script"
echo 'cef-app-size: pre-sign size survives signing failure contract passed'
