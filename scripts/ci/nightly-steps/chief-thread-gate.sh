#!/usr/bin/env bash
# nightly.yml verify-final-dmg-nightly: the Chief thread's structure on the exact DMG publish-nightly
# would put on the cmux NEXT feed, before any appcast names it (after the launch smoke).
#
# usage: chief-thread-gate.sh DMG
#
# Leo, 2026-11-10, on a nightly whose Chief panel drew an avatar column beside grey cards: "latest
# nightly chief UI got completely cooked we have massive regression what happened" ... "Where's the
# spec for that? Where's the iMessage". scripts/ci/chief_thread_smoke.py launches the app from a fresh
# home, opens the Chief and Home, reads the accessibility tree (tests/ui-structure/ax_dump.swift) and
# checks it against tests/ui-structure/chief-thread.json.
#
#   pass        exit 0.
#   fail        exit 1: a shown thread broke the spec (an avatar or list column beside the Chief's
#               thread, full-width cards, misaligned bubbles, oversized attachments, a repeated Needs
#               you): the verify job fails and publish-nightly publishes nothing of this build.
#   cannot-run  exit 0 with a warning: no GUI session, no accessibility trust, no thread shown, or a
#               harness error. A smoke never holds a build it could not check (Leo, 2026-10-23: a smoke
#               must never block the whole nightly).
#
# Bounded at CHIEF_THREAD_GATE_SECONDS (default 240) so it stays inside its 5 minute step.
set -uo pipefail

dmg="${1:?usage: chief-thread-gate.sh DMG}"
ci="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$ci/../.." && pwd)"
dir="${RUNNER_TEMP:?}/chief-thread"
SECONDS_BOUND="${CHIEF_THREAD_GATE_SECONDS:-240}"
mkdir -p "$dir" && chmod 0777 "$dir"

cannot_run() {
  echo "::warning title=Chief thread structure::$1; the build is not held"
  printf '### Chief thread structure: cannot-run\n\n%s\n' "$1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
}

[ -f "$dmg" ] || cannot_run "no DMG at $dmg"
for f in "$ci/chief_thread_smoke.py" "$ci/fresh_home_launch_smoke.py" "$repo/tests/ui-structure/ax_dump.swift" \
  "$repo/tests/ui-structure/thread_structure.py" "$repo/tests/ui-structure/chief-thread.json"; do
  [ -f "$f" ] || cannot_run "the gate's tooling has no $f"
done

# shellcheck source=/dev/null
source "$ci/lib/signing-runtime-guard.sh"
cmux_signing_runtime_guard || cannot_run "a signing keychain is still present in this job"

swiftc -O "$repo/tests/ui-structure/ax_dump.swift" -o "$dir/ax_dump" 2> "$dir/swiftc.log" \
  || cannot_run "ax_dump.swift did not compile: $(head -c 400 "$dir/swiftc.log")"

status=0
"$ci/frame-pacing/console-session.sh" python3 -I "$ci/chief_thread_smoke.py" \
  --dmg "$dmg" --out "$dir" --seconds 8 --startup-timeout 90 --ax-dump "$dir/ax_dump" &
pid=$!
rm -f "$dir/timed-out"
perl -e '($s, $p, $m) = @ARGV; sleep $s; open(my $f, ">", $m); close $f; kill "TERM", $p; sleep 30; kill "KILL", $p' \
  "$SECONDS_BOUND" "$pid" "$dir/timed-out" &
watchdog=$!
wait "$pid" || status=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null
[ -e "$dir/timed-out" ] && cannot_run "the check was still running after ${SECONDS_BOUND}s"

summary="$(python3 -I - "$dir/report.json" <<'PY'
import json, sys
try:
    report = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("no report"); sys.exit(0)
result = report.get("chief_thread") or {}
print(f"verdict: {result.get('verdict')}  {result.get('why') or ''}")
for surface, entry in (result.get("surfaces") or {}).items():
    found = entry.get("violations")
    print(f"- {surface}: " + (entry.get("why") or ("pass" if not found else f"{len(found)} violation(s)")))
    for v in found or []:
        print(f"  - {v['rule']}: {v['detail']}")
for failure in report.get("failures") or []:
    print(f"- {failure}")
PY
)"
printf '### Chief thread structure (exit %s)\n\n%s\n' "$status" "$summary" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "$summary"
case "$status" in
  0) echo "Chief thread structure passed" ;;
  1)
    echo "::error title=Chief thread structure::the candidate's Chief or Home thread breaks tests/ui-structure/chief-thread.json; this build is not published"
    exit 1 ;;
  *) cannot_run "the check could not run here (exit $status)" ;;
esac
