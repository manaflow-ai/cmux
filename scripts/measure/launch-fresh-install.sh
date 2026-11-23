#!/usr/bin/env bash
# Where a new copy's first launch spends its ~3 s, and which part a window can come before (Leo, 2026-11-17: "the whole
# point is a fresh launch somebody installing and launching from scratch"). On a fleet Mac's console session, one DMG:
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-fresh-install.sh --ref <sha> [--arg=dmg=nightly|URL|sha256:HEX] [--arg=reps=5] \
#     [--arg=rows=n,q,m,p] [--arg=trace=1] --artifact .build/launch-fresh-install/report.tgz --timeout 5400
# dmg= is as launch-premain.sh takes it (sha256:HEX: the fleet store, a pull request's signed candidate). Rows, each
# launch the first open of a copy nothing has run, with an empty home (a person's first launch), opened through
# LaunchServices as a double-click opens it:
#   n   a new copy, not quarantined: ditto from the mounted DMG (an update's copy with no pre-warm)
#   q   the real fresh install: a DMG file quarantined as a browser download marks it, mounted, the app copied into
#       /Applications as a drag copies it (ditto, the volume's quarantine kept), opened there
#   m   the same quarantined DMG, the app opened from the mounted volume
#   p   as n, then the updater pre-warm's first step run on the copy before the open (its executable with
#       --cmux-prewarm-launch, StagedUpdatePrewarm: exec and dyld, then exit), as an installer of ours could run it
#   s   as n, the executable started directly (posix_spawn, suspended) and stopped at main: spawn_ms is the kernel's
#       exec of the image (its signature and policy check), resume_to_main is dyld, the frameworks it links and
#       initializers. Splits a new copy's wait between exec and dyld with no root and no prompt.
#   x   as n, but the first thing run on the new copy is the exec of a small separately signed bundle inside it (the
#       smallest Chromium helper app's executable, spawned suspended and killed): spawn_ms says whether a nested
#       bundle's first exec pays only its own check or the whole app's, which is what a small stub bundle would pay
# Every launch gets a new DMG file (q, m) or a new copy (n) and a new quarantine event, so no row reuses a check.
# Per launch, ms from the open request: the system's "downloaded from the Internet" prompt on screen and gone (its Open
# pressed by the console's CuaDriver at once, so a person's reading time is not in the row), the process start, `main`
# (the app's main_start mark: the framework's code on a stub build), the first window on screen, and usable (the
# window_usable mark: Home's field has the keys). And the CPU syspolicyd, XprotectService, amfid and trustd spent
# across it, whether the app ran translocated, and the copy's quarantine attribute before and after.
# trace=1 adds one traced launch per row, not in the medians: fs_usage (root) across it and the system log of the
# checkers, reduced to LF-TRACE: when the app's process made its first file call (dyld's first look: everything
# before it is before the executable's first instruction), when it opened CmuxNextApp.framework and Chromium's
# framework, and the checkers' first and last read of the copy's files.
# Prints LF-LAYOUT once (the build's layout; layout.txt in the report has the ls, otool -L and codesign -dv it rests
# on), LF-RUN per launch, LF-TABLE per row, LF-TRACE per traced launch. Deletes every copy and DMG it made.
# With row q or m it declares the Gatekeeper prompts it raises to the fleet's dialog alarm (a marker in
# /Users/Shared/cmux-build-fleet/expected-dialogs, removed on exit) and answers each itself: Open for the measured open, Cancel for one still up after a launch or at exit (LF-PROMPT lines). It never presses
# anything on a keychain or password panel; each launch's home gets its own login keychain so none comes up.
set -uo pipefail

LF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# store_fetch, gate, checker_cpu, load1, wait_load from the pre-main study's harness (its main does not run).
source "$LF_DIR/launch-premain.sh"

main() {
  cd "$LF_DIR/../.." || exit 3
  local out="$PWD/.build/launch-fresh-install" dmg=nightly reps=5 rows="n,q,m,p" trace=0 arg rc=0 rep row
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=https://*|dmg=sha256:*) dmg="${arg#dmg=}" ;;
      reps=*) reps="${arg#reps=}" ;;
      rows=*) rows="${arg#rows=}" ;;
      trace=0|trace=1) trace="${arg#trace=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$reps" =~ ^([1-9]|1[0-2])$ ]] || { echo "reps= must be 1 to 12" >&2; exit 2; }
  [[ "$rows" =~ ^[nqmpsx](,[nqmpsx])*$ ]] || { echo "rows= takes n,q,m,p,s,x" >&2; exit 2; }
  echo "LF host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  sudo -n true 2>/dev/null && echo "LF root yes" || echo "LF root no (trace=1 needs it for fs_usage)"
  xcrun swiftc -O -o "$out/launch-premain" scripts/measure/launch-premain.swift >"$out/swiftc.log" 2>&1 \
    || { echo "LF probe build failed"; cat "$out/swiftc.log"; exit 3; }
  if [[ "$dmg" == nightly ]]; then
    dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
      | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  fi
  if [[ "$dmg" == sha256:* ]]; then
    [[ "$dmg" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "dmg=sha256: takes 64 lowercase hex" >&2; exit 2; }
    echo "LF dmg $dmg"
    store_fetch "${dmg#sha256:}" "$out/app.dmg" || { echo "LF download failed"; exit 3; }
  else
    [[ "$dmg" == https://* ]] || { echo "LF no nightly DMG in the feed"; exit 3; }
    echo "LF dmg $dmg"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-fresh-install/1 -o "$out/app.dmg" "$dmg" || { echo "LF download failed"; exit 3; }
  fi
  gate dmg open "$out/app.dmg"
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  # The build's layout (bundle_layout: stub executable and CmuxNextApp.framework or not), from the DMG's own app.
  mkdir -p "$out/mnt-layout"
  if hdiutil attach "$out/app.dmg" -nobrowse -readonly -noautofsck -mountpoint "$out/mnt-layout" >/dev/null; then
    bundle_layout "$(find "$out/mnt-layout" -maxdepth 1 -name '*.app' | head -1)" "$out/layout.txt" LF
    hdiutil detach "$out/mnt-layout" >/dev/null || hdiutil detach -force "$out/mnt-layout" >/dev/null
  else
    echo "LF-LAYOUT unknown: attach failed"
  fi
  OUT="$out"
  CUA=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
  [[ -x "$CUA" ]] && echo "LF cua $(console "$CUA" permissions status 2>&1 | tr '\n' ' ' | head -c 200)" || echo "LF cua none: a prompt cannot be pressed"
  # Where q drags the app: /Applications when the console user may write it, as on a person's Mac; else ~/Applications.
  APPS=/Applications
  console /bin/test -w /Applications || APPS="$(console /bin/sh -c 'mkdir -p "$HOME/Applications" && echo "$HOME/Applications"')"
  echo "LF applications $APPS"
  RUN_ID="lf$$-$(date +%s)"
  local list; IFS=, read -r -a list <<<"$rows"
  # The prompts on screen before the first row are not this job's: no sweep presses them.
  PROMPT_BASELINE="$(prompts ids 2>/dev/null)"
  # Rows q and m raise Gatekeeper's prompt on purpose: say so to the fleet's dialog alarm for this run, and take the
  # word back on every exit, after a last sweep of any prompt the job left.
  trap 'sweep_prompts Cancel exit; marker_remove' EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  [[ ",$rows," == *,q,* || ",$rows," == *,m,* ]] && marker_write
  if [[ "$trace" == 1 ]]; then
    for row in "${list[@]}"; do wait_load "$row" T; first "$row" T || rc=1; done
  fi
  for ((rep = 1; rep <= reps; rep++)); do
    local n=${#list[@]} k
    for ((k = 0; k < n; k++)); do
      row="${list[$(((k + rep - 1) % n))]}"
      wait_load "$row" "$rep"
      first "$row" "$rep" || rc=1
    done
  done
  python3 -I - "$out/runs.jsonl" <<'PY'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    return {"median": round(statistics.median(vals), 1), "min": min(vals), "max": max(vals), "n": len(vals)} if vals else None
for name in dict.fromkeys(r["row"] for r in rows):
    runs = [r for r in rows if r["row"] == name and r.get("rep") != "T" and r.get("mode") in ("first", "exec", "spawn")]
    table = {"row": name, "n": len(runs), "errors": sum(1 for r in runs if r.get("error")),
             "translocated": sum(1 for r in runs if r.get("translocated")),
             "prompted": sum(1 for r in runs if isinstance(r.get("prompt"), (int, float))),
             # Launches that started with an unanswered prompt of an earlier launch on screen, and that left one.
             "prompts_before": sum(1 for r in runs if r.get("prompts_before")),
             "prompt_left": sum(1 for r in runs if r.get("prompt_left"))}
    for key in ("prompt", "prompt_gone", "start", "main", "window", "usable", "main_start",
                "syspolicyd_ms", "xprotect_ms", "amfid_ms", "trustd_ms", "mount_ms", "prepare_checker_ms", "prewarm_ms",
                "spawn_ms", "resume_to_main", "request_to_start"):
        table[key] = med([r.get(key) for r in runs])
    # The prompt's dwell (on screen to dismissed) is a person's click, not ours to cut: window, usable and main are
    # reported as measured above and again with the dwell subtracted (*_less_dwell; equal to the measured value when
    # no prompt showed). window_after_prompt is the window's time after the prompt was gone.
    num = lambda v: isinstance(v, (int, float))
    def dwell(r):
        return r["prompt_gone"] - r["prompt"] if num(r.get("prompt")) and num(r.get("prompt_gone")) else 0
    table["dwell"] = med([dwell(r) for r in runs if num(r.get("prompt")) and num(r.get("prompt_gone"))])
    for key in ("main", "window", "usable"):
        table[key + "_less_dwell"] = med([r[key] - (dwell(r) if num(r.get("prompt")) and r["prompt"] < r[key] else 0)
                                          for r in runs if num(r.get(key))])
    table["window_after_prompt"] = med([r["window"] - r["prompt_gone"] for r in runs
                                        if num(r.get("window")) and num(r.get("prompt_gone"))])
    print("LF-TABLE", json.dumps(table), flush=True)
PY
  tar -czf "$out.tgz" -C "$out" --exclude '*.dmg' --exclude 'copy-*' --exclude 'mnt-*' --exclude 'home-*' . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# console CMD...: launch-premain.sh's (sourced above), as is fresh_keychain.

# The fleet's dialog alarm (cmuxterm-hq, "expected dialogs") pages for every system prompt on a fleet Mac's screen
# unless a live job declared it: one marker per run, <owner>-<pid>.json, written atomically, its expiry at most 2 h
# away (the reader ignores a marker with a dead pid, a past expiry, or an expiry over 2 h after its mtime). Only
# "gatekeeper": a keychain or password panel (SecurityAgent, coreautha) always pages, whatever a marker says.
EXPECTED_DIALOGS_DIR="${LF_EXPECTED_DIALOGS_DIR:-/Users/Shared/cmux-build-fleet/expected-dialogs}"
# The job's own bound: the cmux-ci --timeout the header gives (5400 s), at most 2 h.
MARKER_BOUND_S="${LF_MARKER_BOUND_S:-5400}"
((MARKER_BOUND_S > 7200)) && MARKER_BOUND_S=7200
MARKER="" MARKER_EXPIRES=0

# marker_write: this run's marker, expiring now + the bound (a run that outlives it rewrites it: marker_refresh).
marker_write() {
  local file="$EXPECTED_DIALOGS_DIR/launch-fresh-install-$$.json" tmp expires
  if [[ ! -d "$EXPECTED_DIALOGS_DIR" ]]; then
    mkdir -p "$EXPECTED_DIALOGS_DIR" 2>/dev/null && chmod 1777 "$EXPECTED_DIALOGS_DIR" 2>/dev/null \
      || { echo "LF expected-dialogs: cannot make $EXPECTED_DIALOGS_DIR; the alarm will page for this run's prompts"; return 0; }
  fi
  expires=$(($(date +%s) + MARKER_BOUND_S))
  tmp="$(mktemp "$EXPECTED_DIALOGS_DIR/.launch-fresh-install-$$.tmp.XXXXXX")" \
    || { echo "LF expected-dialogs: cannot write in $EXPECTED_DIALOGS_DIR"; return 0; }
  if python3 -I -c '
import datetime, json, sys
expires = datetime.datetime.fromtimestamp(int(sys.argv[2]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps({"schema": "expected-dialogs/v1", "kinds": ["gatekeeper"], "owner": "launch-fresh-install",
                  "pid": int(sys.argv[1]), "expires": expires}))' "$$" "$expires" >"$tmp" \
      && chmod 0644 "$tmp" && mv -f "$tmp" "$file"; then
    MARKER="$file" MARKER_EXPIRES=$expires
    echo "LF expected-dialogs $file expires $expires"
  else
    rm -f "$tmp"; echo "LF expected-dialogs: marker not written"
  fi
}

# marker_refresh: rewrite the marker when less than 15 min of it is left (a long run, many reps).
marker_refresh() { [[ -n "$MARKER" ]] && (($(date +%s) + 900 > MARKER_EXPIRES)) && marker_write; return 0; }

marker_remove() { [[ -n "$MARKER" ]] && rm -f "$MARKER"; MARKER=""; }

# prompts ARGS...: launch-fresh-install-prompts.py in the console session, with the console's CuaDriver.
prompts() {
  [[ -x "${CUA:-}" ]] || return 1
  console /usr/bin/python3 -I "$LF_DIR/launch-fresh-install-prompts.py" "$CUA" "$@"
}

# sweep_prompts Open|Cancel WHEN: press the button on each "downloaded from the Internet" prompt this job raised (none
# from before it), and name any keychain or password panel on screen (never pressed): LF-PROMPT lines.
sweep_prompts() { prompts press "$1" "${PROMPT_BASELINE:-}" "$2" 2>>"${OUT:-/tmp}/prompts.log"; return 0; }

# quarantine FILE: a quarantine attribute as a browser's download writes it (flags 0083, now, the agent, a new event).
quarantine() {
  xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$1"
}

qattr() { xattr -p com.apple.quarantine "$1" 2>/dev/null || echo none; }

# cpu_delta BEFORE AFTER: the checkers' summed CPU ms between two checker_cpu readings.
cpu_delta() {
  awk -v b="$1" -v a="$2" 'BEGIN { n = split(b, x, " "); split(a, y, " "); t = 0
    for (i = 1; i <= n; i++) { split(x[i], p, "="); split(y[i], q, "="); t += q[2] - p[2] }; print t }'
}

now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }

# first ROW REP: one copy made as ROW makes it, its first open measured, then the copy and its DMG deleted.
first() {
  local name="$1" rep="$2" tag="$1-$2" mount app dmgfile copied_by=none dir before after line rc=0
  mount="$OUT/mnt-$tag" dmgfile="$OUT/$tag.dmg"
  mkdir -p "$mount" "$OUT/home-$tag" && chmod 0777 "$OUT/home-$tag"
  cp "$OUT/app.dmg" "$dmgfile" || return 1
  local mounted_by=hdiutil mount_ms=null prewarm_ms=null cpu_prepare
  cpu_prepare="$(checker_cpu)"
  # Every row mounts with hdiutil, unbrowsed, at the job's own mount point. Rows q and m quarantine the DMG file first;
  # hdiutil carries that onto the volume's files, so the copy (q) and the mounted app (m) are quarantined as a
  # download's are. -noautofsck: hdiutil checks a quarantined image with fsck_apfs before mounting it, and fsck_apfs
  # reading the image's device asks "would like to access files on a removable volume" in the worker's name
  # (cmux-austin-mini-0, 2026-11-19 10:53Z, tccd: accessing fsck_apfs, responsible the worker). Never `open DMG`: DiskImageMounter mounts it under /Volumes, where a walk of the job (or of anything
  # else on the Mac) asks "would like to access files on a removable volume" in the worker's name, and it stayed mounted
  # after the run (cmux-austin-mini-0, 2026-11-19, job c5408b53).
  if [[ "$name" == q || "$name" == m ]]; then
    quarantine "$dmgfile"
    marker_refresh
  fi
  hdiutil attach "$dmgfile" -nobrowse -readonly -noautofsck -mountpoint "$mount" >/dev/null || { echo "LF attach failed $tag"; return 1; }
  local found; found="$(find "$mount" -maxdepth 1 -name '*.app' | head -1)"
  case "$name" in
    n|p|s|x) dir="$OUT/copy-$tag"; mkdir -p "$dir"; ditto "$found" "$dir/$(basename "$found")" && copied_by=ditto
       app="$dir/$(basename "$found")" ;;
    q) dir="$APPS/cmux-fresh-install-$RUN_ID-$tag"
       console /bin/mkdir -p "$dir"
       # ditto keeps the volume's quarantine, as a drag's copy does. Never Finder's copy through osascript: an Apple
       # event to Finder asks "wants access to control Finder" on a screen nobody answers (cmux-austin-mini-0,
       # 2026-11-19), and the row fell back to ditto anyway.
       console /usr/bin/ditto "$found" "$dir/$(basename "$found")" && copied_by=ditto
       app="$dir/$(basename "$found")" ;;
    m) app="$found"; copied_by=mounted ;;
  esac
  [[ "$name" != m ]] && { hdiutil detach "$mount" >/dev/null || hdiutil detach -force "$mount" >/dev/null; }
  if [[ "$name" == p ]]; then
    local exe t_warm
    exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
    t_warm="$(now_ms)"
    console /usr/bin/perl -e 'alarm 60; exec @ARGV' "$exe" --cmux-prewarm-launch >/dev/null 2>&1
    prewarm_ms=$(($(now_ms) - t_warm))
  fi
  # What the checkers spent while the DMG was mounted and the copy made (and pre-warmed, row p): before the open.
  local prepare_checker_ms; prepare_checker_ms="$(cpu_delta "$cpu_prepare" "$(checker_cpu)")"
  before="$(qattr "$app")"
  local fw="$app/Contents/Frameworks/CmuxNextApp.framework/CmuxNextApp" fwq
  fwq="$(qattr "$fw")"
  local cpu_before trace_pid="" t0
  cpu_before="$(checker_cpu)"
  if [[ "$rep" == T ]] && sudo -n true 2>/dev/null; then
    # fs_usage itself under sudo (a fleet host's sudoers allows /usr/bin/fs_usage, not a shell); the redirect stays in
    # this unprivileged shell. -t 70 ends it after the launch's 60 s bound; the plain kill below ends it sooner (sudo
    # runs with this user's real uid, so it takes the signal and passes it to fs_usage).
    # shellcheck disable=SC2024
    sudo -n /usr/bin/fs_usage -w -t 70 -f filesys -f exec >"$OUT/fs-$tag.txt" 2>&1 &
    trace_pid=$!
    sleep 1
  fi
  # The probe makes $OUT/home-$tag/h the app's HOME (launch-premain.swift environment).
  fresh_keychain "$OUT/home-$tag/h"
  t0="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ "$name" == x ]]; then
    local helper
    helper="$(find "$app/Contents/Frameworks" -maxdepth 1 -name '* Helper*.app' | while read -r h; do
      e="$h/Contents/MacOS/$(basename "$h" .app)"; [[ -x "$e" ]] && echo "$(stat -f %z "$e") $e"; done | sort -n | head -1 | cut -d' ' -f2-)"
    line="$(console "$OUT/launch-premain" spawn "$helper" "$tag" 2>>"$OUT/probe.log" | grep '^LP-RUN ')" || rc=1
  elif [[ "$name" == s ]]; then
    # The hold file exists before the spawn: the probe resumes the suspended child as soon as it has its pid.
    touch "$OUT/hold-$tag" && chmod 0666 "$OUT/hold-$tag"
    line="$(console "$OUT/launch-premain" exec "$app" "$OUT/home-$tag" "$tag" "$OUT/hold-$tag" 2>>"$OUT/probe.log" | grep '^LP-RUN ')" || rc=1
    rm -f "$OUT/hold-$tag"
  else
    line="$(console /usr/bin/env LF_CUA="$CUA" "$OUT/launch-premain" first "$app" "$OUT/home-$tag" "$tag" 3 2>>"$OUT/probe.log" | grep '^LP-RUN ')" || rc=1
  fi
  local cpu_after; cpu_after="$(checker_cpu)"
  after="$(qattr "$app")"
  [[ -n "$trace_pid" ]] && { kill -INT "$trace_pid" 2>/dev/null; wait "$trace_pid" 2>/dev/null; }
  [[ "$rep" == T ]] && log show --start "$t0" --style compact \
    --predicate 'process == "syspolicyd" OR process == "XprotectService" OR process == "amfid" OR sender == "AppleSystemPolicy" OR sender == "AppleMobileFileIntegrity"' \
    >"$OUT/log-$tag.txt" 2>&1
  [[ -z "$line" ]] && line='LP-RUN {"error": "no result"}'
  local json
  json="$(echo "${line#LP-RUN }" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
b = dict(p.split("=") for p in sys.argv[4].split()); a = dict(p.split("=") for p in sys.argv[5].split())
for k in b: r[k + "_ms"] = int(a[k]) - int(b[k])
r.update(row=sys.argv[1], rep=sys.argv[2] if sys.argv[2] == "T" else int(sys.argv[2]), copied_by=sys.argv[3],
         quarantine_before=sys.argv[6], quarantine_after=sys.argv[7], framework_quarantine=sys.argv[8], load=float(sys.argv[9]),
         mounted_by=sys.argv[10], mount_ms=json.loads(sys.argv[11]), prewarm_ms=json.loads(sys.argv[12]),
         prepare_checker_ms=int(sys.argv[13]))
print(json.dumps(r, sort_keys=True))' "$name" "$rep" "$copied_by" "$cpu_before" "$cpu_after" "$before" "$after" "$fwq" "$(load1)" \
    "$mounted_by" "$mount_ms" "$prewarm_ms" "$prepare_checker_ms")"
  echo "LF-RUN $json"
  # Every process this copy left (the app, its helpers, the daemons a quit keeps), from the copy or where it ran
  # translocated.
  local ran pids
  ran="$(printf '%s' "$json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("ran_from") or "")')"
  pids="$(ps -axo pid=,command= | LF_A="$app/" LF_B="${ran:-$app}/" awk 'index($0, ENVIRON["LF_A"]) || index($0, ENVIRON["LF_B"]) { print $1 }')"
  [[ -n "$pids" ]] && { sudo -n kill $pids 2>/dev/null || kill $pids 2>/dev/null; }
  sleep 1
  # The measured open is over: a prompt still up (a press that missed, one a copy's helper raised) is not needed.
  # Cancel it now, while its copy exists; with the copy deleted under it, it stays as '"(null)" is an app downloaded
  # from the Internet'.
  [[ "$name" == q || "$name" == m ]] && sweep_prompts Cancel "after $tag"
  echo "$json" >>"$OUT/runs.jsonl"
  [[ "$rep" == T ]] && trace_row "$tag" "$app" "$json"
  # Only what this launch made: the copy (or the mount) and its DMG file.
  case "$name" in
    n|p|s|x) rm -rf "$OUT/copy-$tag" ;;
    q) console /bin/rm -rf "$dir" ;;
    m) hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 ;;
  esac
  rm -f "$dmgfile"
  rm -rf "$OUT/home-$tag"
  [[ "$json" != *'"error"'* ]] && return "$rc"
  return 1
}

# trace_row TAG APP RUNJSON: fs-TAG.txt and log-TAG.txt reduced to one LF-TRACE row (launch-fresh-install-trace.py).
trace_row() {
  python3 -I "$LF_DIR/launch-fresh-install-trace.py" "$OUT/fs-$1.txt" "$OUT/log-$1.txt" "$2" "$3"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
