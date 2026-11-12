#!/usr/bin/env bash
# nightly.yml verify-final-dmg-nightly and verify-recovered-nightly-next: the fresh-home launch smoke
# of the exact DMG publish-nightly would put on the cmux NEXT feed, before any appcast names it.
#
# usage: launch-smoke-gate.sh DMG
#
# The harness comes from this script's own scripts/ci (fresh_home_launch_smoke.py,
# nightly_next_launch_smoke.py, frame-pacing/console-session.sh, lib/signing-runtime-guard.sh): the
# workflow commit's, which a build checked out at an older commit may not have.
#
# Leo, 2026-10-29, on a build that Sparkle downloaded and that was pulled afterwards: "Just don't
# have that be the downloading thing." So a build that crashes at launch fails this step: the verify
# job fails, publish-nightly publishes nothing of it, and the feed keeps serving the build it has.
#
# Two homes, one harness call (--arms empty,seeded). Build 4294166855401 (2616865988e1) crashed at
# launch on its thread cmux-cookie-sync, but only for a person whose imported cookies were kept in
# sync; this gate launched it from an empty home and passed it. So after the empty home passes, the
# harness launches the same app copy from a home it seeds with made-up data: imported-cookie sync on
# and a cookie store with rows (fresh_home_launch_smoke.py seed_cookie_sync_home; no keychain read).
# A normal run is about 13 s longer; a hung attempt is still cut at LAUNCH_SMOKE_ATTEMPT_SECONDS.
#
#   pass        exit 0.
#   crash       exit 1: the app launched and then exited, wrote a crash report or recorded an
#               uncaught exception, on both of two attempts (nightly_next_launch_smoke.py verdict),
#               from either home. The same holds for an app that shows Home and says, when the
#               harness's watch ends and again 5 s later, that its daemon is not connected (the
#               report's `daemon_down`; --daemon, asked here only: the post-publish smoke does not
#               ask, so a daemon never rolls a published build back). One attempt of each kind
#               holds too, and the error line says each attempt's own cause. A live app that never renders
#               Home is a failed smoke but does not trigger rollback. An attempt that the watchdog
#               cut counts when its report already says so: the harness writes its verdict before
#               it keeps the evidence, and a build
#               that crashed in both attempts is not published because the evidence was slow.
#   cannot-run  exit 0 with a warning: no GUI session, a harness or infrastructure error before the
#               app launched, or a check cut short of a verdict. The smoke never holds a build the harness could
#               not launch (Leo, 2026-10-23: a smoke must never block the whole nightly); the
#               post-publish smoke (nightly-next-launch-smoke.yml) still smokes it from the feed and
#               rolls it back if it crashes. A seeded home that could not be made, or whose cookie
#               store the app never read, changes no exit code: the empty home's verdict stands (the
#               harness exits as it would without that arm, and its report's `arms` says "not-run" or
#               "cannot-run"). A pass then carries a warning and a summary line that the seeded home
#               was not checked, so a pass of the empty home alone is never read as a pass of both.
#               A pass also carries a warning and a summary line when a home's last daemon read was
#               not "connected" (no answer, no such field): the app launched, its daemon was not
#               judged, and the build is not held.
#               Also a pass whose app used the daemon of another launch: the daemon's socket is the
#               account's, by session, so on a host where a build of the same channel is live the
#               app says "connected" of THAT daemon (the report's `of_launch`). The warning says so:
#               the daemon was not judged, and that is never a pass.
#
# Evidence goes to $RUNNER_TEMP/launch-smoke (attempt-N/, status-N, evidence.md) and the job summary.
set -uo pipefail

dmg="${1:?usage: launch-smoke-gate.sh DMG}"
ci="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${RUNNER_TEMP:?}/launch-smoke"
ATTEMPT_SECONDS="${LAUNCH_SMOKE_ATTEMPT_SECONDS:-240}"
KILL_GRACE="${LAUNCH_SMOKE_KILL_GRACE:-60}"
mkdir -p "$dir"

cannot_run() {
  echo "::warning title=nightly-next launch smoke::$1; the build is not held (the post-publish smoke still checks it)"
  printf '### Launch smoke: cannot-run\n\n%s\n' "$1" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
}

[ -f "$dmg" ] || cannot_run "no DMG at $dmg"
for f in fresh_home_launch_smoke.py nightly_next_launch_smoke.py frame-pacing/console-session.sh lib/signing-runtime-guard.sh; do
  [ -f "$ci/$f" ] || cannot_run "the smoke tooling has no scripts/ci/$f"
done

# Bundle code never runs while a signing keychain exists, and gets no credentials.
# shellcheck source=/dev/null
source "$ci/lib/signing-runtime-guard.sh"
cmux_signing_runtime_guard || cannot_run "a signing keychain is still present in this job"

# Two attempts: one flaky launch never holds a build. Exit 0 passes, 1 is a crash, and so is a cut
# attempt whose report says that the app ended; anything else could not run and ends the check.
for attempt in 1 2; do
  out="$dir/attempt-$attempt"
  mkdir -p "$out" && chmod 0777 "$out"
  # The report is read after a cut, so it must be this attempt's: a harness that is killed writes none,
  # and a report that an earlier run left in this folder is not this launch. The folder is the gate's own.
  rm -f "${out:?}/report.json" || cannot_run "an old report in $out cannot be removed"
  status=0
  "$ci/frame-pacing/console-session.sh" python3 -I "$ci/fresh_home_launch_smoke.py" \
    --dmg "$dmg" --out "$out" --arms empty,seeded --daemon &
  pid=$!
  # The watchdog bounds an attempt, so a hung harness never holds the job until its step timeout
  # (which would fail it like a crash). It sends SIGTERM, which the harness handles by stopping the
  # app and putting the defaults back (console-session.sh's sudo relays it), then SIGKILL after
  # KILL_GRACE. A cut-off attempt has the status 124 whatever it exits with; what it is (cannot-run,
  # or a crash that the harness saw before the cut) is read from its report, never from its exit.
  rm -f "$dir/timed-out-$attempt"
  perl -e '($s, $g, $p, $m) = @ARGV; sleep $s; open(my $f, ">", $m); close $f; kill "TERM", $p;
    sleep $g; kill "KILL", $p' "$ATTEMPT_SECONDS" "$KILL_GRACE" "$pid" "$dir/timed-out-$attempt" &
  watchdog=$!
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ -e "$dir/timed-out-$attempt" ]; then
    echo "launch smoke attempt $attempt: still running after ${ATTEMPT_SECONDS}s, stopped"
    status=124
  fi
  echo "$status" > "$dir/status-$attempt"
  echo "launch smoke attempt $attempt: exit $status"
  [ "$status" = 1 ] && continue
  # A cut attempt gets its second attempt only when it is a crash; any other cut ends the check.
  [ "$status" = 124 ] && [ "$(python3 -I "$ci/nightly_next_launch_smoke.py" attempt --dir "$dir" --number "$attempt" --daemon 2>/dev/null)" = crash ] || break
done

verdict="$(python3 -I "$ci/nightly_next_launch_smoke.py" verdict --dir "$dir" --daemon)" || cannot_run "the verdict could not be read"
last=""
for d in "$dir"/attempt-1 "$dir"/attempt-2; do [ -d "$d" ] && last="$d"; done
crashes=()
for f in "$last"/*.ips "$last"/*.crash; do [ -f "$f" ] && crashes+=(--crash "$f"); done
python3 -I "$ci/nightly_next_launch_smoke.py" evidence --report "$last/report.json" \
  --app-log "$last/app.log" ${crashes[@]+"${crashes[@]}"} --out "$dir/evidence.md" \
  || printf 'No evidence could be summarised; see the launch-smoke artifact.\n' > "$dir/evidence.md"
{
  echo "### Launch smoke: $verdict"
  echo ""
  cat "$dir/evidence.md"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

case "$verdict" in
  pass)
    echo "launch smoke passed"
    # Said, never held: the seeded home's arm when it is not a pass (report.json's `arms`).
    unchecked="$(python3 -I -c 'import json, sys
arm = (json.load(open(sys.argv[1])).get("arms") or {}).get("seeded") or {}
verdict = str(arm.get("verdict") or "not-run")
if verdict != "pass":
    reason = " ".join(str(arm.get("reason") or "the harness gave no reason").split())[:300]
    print(f"the seeded home (imported-cookie sync on) was not checked ({verdict}: {reason})")' "$last/report.json" 2>/dev/null)"
    if [ -n "$unchecked" ]; then
      echo "::warning title=nightly-next launch smoke::$unchecked; the empty home passed and the build is not held"
      printf '\nSeeded home: %s. The empty home passed; the build is not held.\n' "$unchecked" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    fi
    # Said, never held: a home that passed with no "connected" in its last daemon read (report.json's `daemon` is the
    # empty home's reads, `arms.seeded.daemon` the seeded home's). The harness does not judge a read with no state,
    # so without this line an app that renames the field turns the daemon check off and nobody sees it.
    unjudged="$(python3 -I -c 'import json, sys
report = json.load(open(sys.argv[1]))
seeded = (report.get("arms") or {}).get("seeded") or {}
homes = [("the empty home", report.get("daemon"))]
if seeded.get("verdict") == "pass":
    homes.append(("the seeded home", seeded.get("daemon")))
silent = [home for home, reads in homes
          if not (isinstance(reads, list) and reads and isinstance(reads[-1], dict) and reads[-1].get("state") == "connected")]
if silent:
    print("the daemon was not judged in " + " and in ".join(silent) + " (the app gave no connected state when it was asked)")' "$last/report.json" 2>/dev/null)"
    if [ -n "$unjudged" ]; then
      echo "::warning title=nightly-next launch smoke::$unjudged; the app launched and the build is not held"
      printf '\nDaemon: %s. The app launched; the build is not held.\n' "$unjudged" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    fi ;;
  crash)
    # Which home each attempt's failure was in: report.json's `arm` (empty, or seeded when the empty home passed). And
    # what it was: the app's end, or (`daemon_down` alone) a live app whose daemon was not connected. The 2 attempts
    # can fail in 2 ways, so each is said by its own report; "on both attempts" only when they say the same.
    what="$(python3 -I -c 'import json, sys
def cause(path):
    report = json.load(open(path))
    home = "a seeded home (imported-cookie sync on)" if report.get("arm") == "seeded" else "a fresh home"
    ended = report.get("exit") or report.get("crash_reports") or report.get("run_exceptions")
    daemon = report.get("daemon_down") and not ended
    return ("the app'"'"'s daemon was not connected after launch" if daemon else "the app crashed at launch") + " from " + home
first, second = cause(sys.argv[1]), cause(sys.argv[2])
print(first + " on both attempts" if first == second else first + " on attempt 1, and " + second + " on attempt 2")' "$dir/attempt-1/report.json" "$dir/attempt-2/report.json" 2>/dev/null)"
    echo "::error title=nightly-next launch smoke::${what:-the app crashed at launch from a fresh home on both attempts}; this build is not published"
    exit 1 ;;
  *)
    # Said, never a pass: the app passed and used the daemon of another launch (report.json's `of_launch`).
    foreign="$(python3 -I -c 'import json, sys
report = json.load(open(sys.argv[1]))
arms = [report] + [arm for arm in (report.get("arms") or {}).values() if isinstance(arm, dict)]
if report.get("verdict") == "pass" and any(read.get("of_launch") is False for arm in arms for read in arm.get("daemon") or []):
    print("the app launched, but the daemon that it used was not of this launch (another build of its session is live on this account), so its daemon was not judged")' "$last/report.json" 2>/dev/null)"
    cannot_run "${foreign:-the smoke could not run here (verdict $verdict)}" ;;
esac
