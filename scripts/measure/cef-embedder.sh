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
# The seeded dist ($CMUX_CI_CEF_DIR) is read-only; the runner copies its framework into the test app and re-signs
# that copy, so it runs on a writable copy of the dist (a read-only copy made codesign fail with its stderr hidden,
# and no case ran: steps 6d191ccb, 100ec79a, 2026-11-02). CMUX_EMBEDDER_INPUT_DIR (tests) takes the test-source
# archive from <dir>/<sha256 hex> instead of the controller store.
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

# Under TMPDIR (the step's own tmp folder): on a lent worker the step folder ($CI_JOB_DIR) belongs to
# root and the build user can write only its home, tmp, cache, src and state folders.
WORK="${TMPDIR:-${CI_JOB_DIR:-/tmp}}/cef-embedder"
[[ ! -e "$WORK" ]] || chmod -R u+w "$WORK"
rm -rf "$WORK"; mkdir -p "$WORK/in" "$WORK/run"
# The copies keep the dist's read-only bits otherwise, and the worker's step cleanup could not remove them.
trap 'chmod -R u+w "$WORK" 2>/dev/null || true' EXIT
CONTROLLER="${CMUX_CI_CONTROLLER:-http://100.89.225.106:18765}"
hex="${SOURCES#sha256:}"
if [[ -n "${CMUX_EMBEDDER_INPUT_DIR:-}" ]]; then
  cp "$CMUX_EMBEDDER_INPUT_DIR/$hex" "$WORK/in/sources.tar.gz" || die "no $SOURCES in $CMUX_EMBEDDER_INPUT_DIR"
else
  url="$(curl -fsS -A cmux-fleet-recipe "$CONTROLLER/v1/artifacts/sha256:$hex/url" |
    /usr/bin/env python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))')" || die "the controller has no $SOURCES for this job"
  [[ "$url" == http* ]] || die "the controller gave no URL for $SOURCES"
  curl -fsS -A cmux-fleet-recipe -o "$WORK/in/sources.tar.gz" "$url" || die "download of $SOURCES failed"
fi
[[ "$(shasum -a 256 "$WORK/in/sources.tar.gz" | cut -c1-64)" == "$hex" ]] || die "$SOURCES: the bytes do not match"
tar -C "$WORK" -xzf "$WORK/in/sources.tar.gz"
[[ "$(tr -d '[:space:]' <"$WORK/src/REF" 2>/dev/null)" == "$FORK_REF" ]] || die "the test-source archive is not $FORK_REF"
grep -q "cmux_cef_api_version" "$cef/include/cef_cmux.h" || die "the CEF dist has no cef_cmux.h"
echo "==> fork $FORK_REF, $(grep -m1 'define CMUX_CEF_API_VERSION' "$cef/include/cef_cmux.h"), cases: ${cases[*]}"

# A writable copy of the dist: the runner re-signs its framework copy.
cp -R "$cef" "$WORK/cef" || die "could not copy the CEF dist to $WORK/cef"
chmod -R u+w "$WORK/cef"
cef="$WORK/cef"
framework="$cef/Chromium Embedded Framework.framework"
if [[ "$(uname)" == Darwin ]]; then
  # The runner signs the same way with its stderr sent to /dev/null; sign here first so a failure says why.
  while IFS= read -r -d '' lib; do
    codesign --force --sign - "$lib" || die "codesign of $lib failed (see above)"
  done < <(find "$framework" -name '*.dylib' -print0)
  codesign --force --sign - "$framework" || die "codesign of the CEF framework failed (see above)"
fi

set +e
CMUX_EMBEDDER_TEST_DIR="$WORK/run" bash "$WORK/src/scripts/test-cmux-embedder.sh" "$cef" "${cases[@]}" 2>&1 | tee "$WORK/log"
rc=${PIPESTATUS[0]}
set -e
passed=$(grep -cE '^    PASS \(' "$WORK/log" || true)
if (( rc != 0 )) && ! grep -q '^==> case ' "$WORK/log"; then
  echo "cmux-embedder: the runner stopped (exit $rc) before its first case; its last lines are above"
fi
# Processes of the tests that outlived them fail the step (ended by pid).
survivors="$(pgrep -f "$WORK/" | grep -vx "$$" || true)"
if [[ -n "$survivors" ]]; then
  echo "cmux-embedder: $(echo "$survivors" | wc -l | tr -d ' ') process(es) outlived the tests (step fails)"
  kill $survivors 2>/dev/null || true
  rc=1
fi
echo "cmux-embedder: $passed/${#cases[@]} passed"
(( rc == 0 && passed == ${#cases[@]} ))
