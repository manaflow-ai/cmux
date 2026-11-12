#!/bin/sh
# cmux machine bootstrap runner, written by the cmux app (cmux cloud new-machine
# --bootstrap-script, --repo). Runs ./repo, then ./script, logs to ./bootstrap.log,
# writes ./status.json.
set -u
d=$(cd "$(dirname "$0")" && pwd)
# One runner at a time; a start while this one runs says `running`.
exec 9>"$d/lock"
flock -n 9 || exit 0
sum=$(sha256sum "$d/script" | cut -d' ' -f1)
key=$(cat "$d/script" "$d/repo" | sha256sum | cut -d' ' -f1)
# A runner launched by an earlier start may have run these files to their end while this one waited
# to be scheduled: a script and repo step that are done are not run again, unless the repo step's
# background fill failed since (machine_bootstrap.rs `FILL_FAILED`): then the step repairs it.
as_u() { "$@"; }
fill_failed() { r=$(cat "$d/repo-status.json" 2>/dev/null) || return 1; case "$r" in *'"fill":"background"'*) ;; *) return 1 ;; esac; f=$(printf '%s\n' "$r" | sed -n 's/.*"dir":"\([^"]*\)".*/\1/p'); [ -n "$f" ] || return 1; x=$(command -v cmux-tui || command -v cmux) || return 1; c=0; as_u "$x" repo wait "$f" 0 >/dev/null 2>&1 || c=$?; [ "$c" = 1 ]; }
if grep -q "\"state\":\"done\".*\"start_sha256\":\"$key\"" "$d/status.json" 2>/dev/null && ! fill_failed; then exit 0; fi
# Held for the runner's whole life, taken blocking: a machine-config apply probes it (shared,
# non-blocking, released at once) to wait while this runner runs; the kernel drops it at the end.
[ -f "$d/alive" ] && [ ! -L "$d/alive" ] || rm -f "$d/alive"
exec 8>"$d/alive"
flock 8
status() {
  repo=$(cat "$d/repo-status.json" 2>/dev/null || echo null)
  printf '{"state":"%s","exit_code":%s,"script_sha256":"%s","start_sha256":"%s","repo":%s,"at":%s%s}\n' "$1" "$2" "$sum" "$key" "$repo" "$(date +%s)" "${3:-}" >"$d/status.json.tmp" &&
    mv -f "$d/status.json.tmp" "$d/status.json"
}
# A runner that comes a minute or more after its start's `starting` does not run: a machine-config apply
# waits that long for a start whose runner never came (with `alive` free), then applies, and a bootstrap
# never runs beside it. Checked once `alive` is held, which the apply sees from then on.
at=$(sed -n 's/^{"state":"starting".*"at":\([0-9]*\)}$/\1/p' "$d/status.json" 2>/dev/null)
if [ -n "$at" ] && [ $(( $(date +%s) - at )) -ge 60 ]; then
  printf '== cmux bootstrap %s: its runner came %ss after the start; start it again\n' "$key" "$(( $(date +%s) - at ))" >>"$d/bootstrap.log"
  status failed 75 ',"late":true'; exit 75
fi
# Not its locks: a daemon the repo step or the script leaves running must not keep them held after this runner ends.
repo_step() { "$d/repo" >>"$d/bootstrap.log" 2>&1 </dev/null 8>&- 9>&-; }
status running null
[ -f "$d/env" ] && . "$d/env"
cd "$HOME" 2>/dev/null || cd /
printf '== cmux bootstrap %s at %s\n' "$key" "$(date -u +%FT%TZ)" >>"$d/bootstrap.log"
repo_step
repo_code=$?
# 3: the repo needs GitHub access the script may set up (a lane VM's broker helper); try again after it.
if [ "$repo_code" -ne 0 ] && [ "$repo_code" -ne 3 ]; then status failed "$repo_code" ',"step":"repo"'; exit "$repo_code"; fi
"$d/script" >>"$d/bootstrap.log" 2>&1 </dev/null 8>&- 9>&-
code=$?; step=script
if [ "$code" -eq 0 ] && [ "$repo_code" -ne 0 ]; then repo_step; code=$?; step=repo; fi
# `step`: which step failed, so a reader never takes a script's exit code for the repo step's.
if [ "$code" -eq 0 ]; then status done 0; else status failed "$code" ",\"step\":\"$step\""; fi
exit "$code"
