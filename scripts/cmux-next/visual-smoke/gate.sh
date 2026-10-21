#!/usr/bin/env bash
# The nightly visual smoke as a CI gate (docs/ci/nightly-next-canary.md,
# "Visual smoke"): smoke-signed-app-cli.sh --visual on a signed app, two
# attempts so one flaky launch does not hold a nightly back. Exits 1 when the
# app looks broken in both. Captures, drive.json and the judge's report.md go
# to <out-dir>/attempt-N; the report also goes to the step summary.
#
# Usage: gate.sh <app-path> <out-dir> [<label>]
set -uo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <app-path> <out-dir> [<label>]" >&2
  exit 2
fi
app="$1"
out="$2"
label="${3:-the signed app}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

for attempt in 1 2; do
  dir="$out/attempt-$attempt"
  if "$here/../../smoke-signed-app-cli.sh" "$app" --visual "$dir"; then
    { echo "### Visual smoke: $label passed (attempt $attempt)"; cat "$dir/report.md" 2>/dev/null; } >>"$summary"
    exit 0
  fi
  echo "::warning title=nightly-next visual smoke::attempt $attempt failed"
done
{ echo "### Visual smoke: $label failed both attempts"; cat "$out/attempt-2/report.md" 2>/dev/null; } >>"$summary"
echo "::error title=nightly-next visual smoke::$label looked broken in both attempts (captures: the nightly-next-visual-smoke artifact)"
exit 1
