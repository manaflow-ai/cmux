#!/usr/bin/env bash
# Fleet entry for the CEF fork's embedder tests against an unreleased fork build (PL-cef-fork,
# plans/cmux-next/cef-helper-app-DESIGN.md section 7): the GUI worker of scripts/cef/test-embedder-step.sh
# (labels gui + cef-embedder) is gone from the fleet, so this runs the same runner on a measure worker
# (a logged-in GUI session; exclusive, because the cases open windows):
#   cmux-ci run --class exclusive --label measure --script scripts/measure/cef-embedder.sh --ref <cmux sha> \
#     --cef sha256:<fork build artifact> --arg sha256:<test-source archive> --arg <fork ref> [--arg <case>]...
# The test-source archive is made as scripts/cef/test-embedder-step.sh describes (the fork is private;
# the host holds no credential) and put in the controller store for this workspace's lane.
# Cases default to the API 30 helper cases. Prints "cmux-embedder: N/M passed"; fails when a case fails.
set -euo pipefail
(( $# >= 2 )) || { echo "usage: cef-embedder.sh sha256:<sources> <fork ref> [case...]" >&2; exit 2; }
SOURCES="$1" FORK_REF="$2"; shift 2
cases=("$@")
(( ${#cases[@]} )) || cases=(helper-input-queue helper-wheel-phase helper-ime helper-ax-token helper-drag-source helper-detached)
die() { echo "cmux-embedder: error: $*" >&2; exit 2; }
[[ "$SOURCES" =~ ^sha256:[0-9a-f]{64}$ ]] || die "SOURCES must be sha256:<64 hex>"
[[ "$FORK_REF" =~ ^[0-9a-f]{40}$ ]] || die "FORK_REF must be a 40-hex commit"
cef="${CMUX_CI_CEF_DIR:?CMUX_CI_CEF_DIR must name the unpacked fork build (cmux-ci run --cef)}"
if [[ ! -d "$cef/include" ]]; then
  cef="$(dirname "$(find "$cef" -maxdepth 3 -type d -name 'Chromium Embedded Framework.framework' | head -1)")"
fi
[[ -d "$cef/include" && -d "$cef/libcef_dll" ]] || die "no CEF dist under CMUX_CI_CEF_DIR"
echo "CEF-EMBEDDER-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) macos=$(sw_vers -productVersion) cef=$cef"

WORK="${CI_JOB_DIR:-${TMPDIR:-/tmp}}/cef-embedder"
rm -rf "$WORK"; mkdir -p "$WORK/in" "$WORK/run"
CONTROLLER="${CMUX_CI_CONTROLLER:-http://100.89.225.106:18765}"
hex="${SOURCES#sha256:}"
url="$(curl -fsS -A cmux-fleet-recipe "$CONTROLLER/v1/artifacts/sha256:$hex/url" |
  /usr/bin/env python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))')" || die "the controller has no $SOURCES for this job"
[[ "$url" == http* ]] || die "the controller gave no URL for $SOURCES"
curl -fsS -A cmux-fleet-recipe -o "$WORK/in/sources.tar.gz" "$url" || die "download of $SOURCES failed"
[[ "$(shasum -a 256 "$WORK/in/sources.tar.gz" | cut -c1-64)" == "$hex" ]] || die "$SOURCES: the bytes do not match"
tar -C "$WORK" -xzf "$WORK/in/sources.tar.gz"
[[ "$(tr -d '[:space:]' <"$WORK/src/REF" 2>/dev/null)" == "$FORK_REF" ]] || die "the test-source archive is not $FORK_REF"
grep -q "cmux_cef_api_version" "$cef/include/cef_cmux.h" || die "the CEF dist has no cef_cmux.h"
echo "==> fork $FORK_REF, $(grep -m1 'define CMUX_CEF_API_VERSION' "$cef/include/cef_cmux.h"), cases: ${cases[*]}"

set +e
CMUX_EMBEDDER_TEST_DIR="$WORK/run" bash "$WORK/src/scripts/test-cmux-embedder.sh" "$cef" "${cases[@]}" 2>&1 | tee "$WORK/log"
rc=${PIPESTATUS[0]}
set -e
passed=$(grep -cE '^    PASS \(' "$WORK/log" || true)
# Processes of the tests that outlived them fail the step (ended by pid).
survivors="$(pgrep -f "$WORK/" | grep -vx "$$" || true)"
if [[ -n "$survivors" ]]; then
  echo "cmux-embedder: $(echo "$survivors" | wc -l | tr -d ' ') process(es) outlived the tests (step fails)"
  kill $survivors 2>/dev/null || true
  rc=1
fi
echo "cmux-embedder: $passed/${#cases[@]} passed"
(( rc == 0 && passed == ${#cases[@]} ))
