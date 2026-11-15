#!/usr/bin/env bash
# Submit the native sidebar suite through the supported fleet runner and fetch its artifact.
# Run from the repository root: scripts/ci/native-sidebar-gallery.sh FULL_SHA
set -euo pipefail

ref="${1:?usage: native-sidebar-gallery.sh FULL_SHA}"
client="${CMUX_CI_CLIENT:-cmux-ci}"
key="native-sidebar-gallery-${ref}-${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}"
receipt="$(mktemp)"
trap 'rm -f "$receipt"' EXIT
status=0
"$client" run --class light --display --script scripts/ci/package-test-lane.sh \
  --ref "$ref" --key "$key" --timeout 2400 \
  --env CMUX_TEST_REQUIRE_GUI=1 \
  --arg suite --arg Packages/macOS/CmuxNext --arg CmuxNextAppTests.NativeSidebarGalleryTests \
  --artifact Packages/macOS/CmuxNext/native-sidebar-gallery.tar 2> "$receipt" || status=$?
cat "$receipt" >&2
[[ "$status" == 0 ]] || exit "$status"

# Read the submitted job ID from the client receipt, then verify its completed source.
job_id="$(python3 -c '
import re, sys
with open(sys.argv[1]) as receipt:
    for line in receipt:
        match = re.match(r"cmux-ci: step ([0-9a-f]{6,64}) \(", line)
        if match:
            print(match[1])
            break
    else:
        sys.exit("native sidebar capture returned no job ID")
' "$receipt")"
job_id="$("$client" status "$job_id" | python3 -c '
import json, sys
job = json.load(sys.stdin)
if (job.get("ref") != sys.argv[1] or job.get("source_digest") != sys.argv[1]
        or job.get("state") != "done" or job.get("exit_code") != 0):
    sys.exit("native sidebar capture has no passing receipt at the requested head")
print(job["id"])
' "$ref")"
mkdir -p artifacts
"$client" artifact "$job_id" artifacts/native-sidebar-gallery.tar
