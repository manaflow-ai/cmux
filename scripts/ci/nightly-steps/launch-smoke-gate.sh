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
#   pass        exit 0.
#   crash       exit 1: the app launched and then exited, wrote a crash report, or never rendered
#               Home, on both of two attempts (nightly_next_launch_smoke.py verdict).
#   cannot-run  exit 0 with a warning: no GUI session, a harness or infrastructure error before the
#               app launched, or a check cut short. The smoke never holds a build the harness could
#               not launch (Leo, 2026-10-23: a smoke must never block the whole nightly); the
#               post-publish smoke (nightly-next-launch-smoke.yml) still smokes it from the feed and
#               rolls it back if it crashes.
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

# Two attempts: one flaky launch never holds a build. Exit 0 passes, 1 is a crash, anything else
# could not run and ends the check.
for attempt in 1 2; do
  out="$dir/attempt-$attempt"
  mkdir -p "$out" && chmod 0777 "$out"
  status=0
  "$ci/frame-pacing/console-session.sh" python3 -I "$ci/fresh_home_launch_smoke.py" \
    --dmg "$dmg" --out "$out" &
  pid=$!
  # The watchdog bounds an attempt, so a hung harness never holds the job until its step timeout
  # (which would fail it like a crash). It sends SIGTERM, which the harness handles by stopping the
  # app and putting the defaults back (console-session.sh's sudo relays it), then SIGKILL after
  # KILL_GRACE. A cut-off attempt is cannot-run whatever it exits with.
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
  [ "$status" = 1 ] || break
done

verdict="$(python3 -I "$ci/nightly_next_launch_smoke.py" verdict --dir "$dir")" || cannot_run "the verdict could not be read"
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
  pass) echo "launch smoke passed" ;;
  crash)
    echo "::error title=nightly-next launch smoke::the app crashed at launch from a fresh home on both attempts; this build is not published"
    exit 1 ;;
  *) cannot_run "the smoke could not run here (verdict $verdict)" ;;
esac
