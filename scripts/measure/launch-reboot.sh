#!/usr/bin/env bash
# Row F (background-ready-copy), the reboot arm: does reading the app's big binaries right after login make the first
# launch after a reboot faster? One phase per cmux-ci measure step, on a measure Mac's console session (passwordless
# sudo for /sbin/shutdown -r now):
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-reboot.sh --ref <sha> --arg=phase=before --arg=reboot=N [--arg=dmg=nightly]
#   cmux-ci run ... --script scripts/measure/launch-reboot.sh --ref <sha> --arg=phase=after --arg=arm=noread|read|residency \
#     --arg=reboot=N
#   phase=before  the copy (installed from dmg= when there is none yet, or on reboot=1) launched once and quit with Keep
#                 Sessions (SIGTERM), every process of it gone, LB-COPY (path, version, sizes), then LB-REBOOT and
#                 exit 0. `sudo -n /sbin/shutdown -r now` runs LB_REBOOT_DELAY s later (default 20), in a session of its
#                 own, so the worker has reported the step done first and never counts the reboot as a lost job.
#   phase=after   the step that runs first after the auto-login. It refuses (LB-FAIL not rebooted, exit 3) while
#                 kern.boottime is still the before step's: one claimed in those 20 s goes again once the host is back.
#                 LB-LOGIN: seconds since kern.boottime and since the loginwindow process started (login;
#                 kern.boottime when there is none). Then, by arm:
#     noread      at login+60 s one measured launch
#     read        at login+5 s each binary read with `/usr/bin/time -l cat FILE >/dev/null` (LB-READ), then at
#                 login+60 s the measured launch
#     residency   the read at login+5 s, each binary's resident fraction at login+1, +10 and +60 min (LB-RESIDENT),
#                 then the measured launch at +60 min (give the step a 75 min timeout)
#   reboot=N      this reboot's number, printed on every row; dmg=nightly|https://...|sha256:HEX as launch-premain.sh.
# The binaries: Contents/MacOS/<executable> (the stub), CmuxNextApp.framework's and Chromium Embedded Framework's
# Versions/A binary, those present. The measured launch is launch-premain.swift's open mode, a Dock-style
# LaunchServices open kept 6 s past its first window and ended with SIGTERM (Keep Sessions): request_to_start,
# main_start, first_frame (first_window_frame_committed), window_on_screen, settle (window_usable, or window + 6 s
# when the app marked none), all ms from the process start but request_to_start; pageins at main; and the CPU
# syspolicyd, XprotectService, amfid and trustd spent across it. Before it, each binary's resident fraction
# (t=prelaunch). Rows: LB-LOGIN, LB-COPY, LB-READ, LB-RESIDENT, LB-LAUNCH, LB-LATE (a wait whose time had passed),
# LB-FAIL REASON (exit 3; 2 for a bad argument). The copy, probe and home live in LB_ROOT (default
# ~/.cmux-launch-reboot), so the after step finds what the before step left.
set -uo pipefail

LB_DIR="$(cd "$(dirname "$0")" && pwd)"
# fetch_dmg, copy_app, checker_cpu, quiesce from the pre-main study's harness (its main does not run).
# shellcheck source=SCRIPTDIR/launch-premain.sh
source "$LB_DIR/launch-premain.sh"

ROOT="${LB_ROOT:-$HOME/.cmux-launch-reboot}"
CONSOLE="${LB_CONSOLE:-scripts/ci/frame-pacing/console-session.sh}"
TIME_BIN="${LB_TIME:-/usr/bin/time}"
PLISTBUDDY="${LB_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
PROBE="$ROOT/launch-premain"
PHASE="" ARM="" REBOOT="" LOGIN="" APP="" FILES=()

main() {
  cd "$LB_DIR/../.." || exit 3
  local dmg=nightly arg
  for arg in "$@"; do
    case "$arg" in
      phase=before|phase=after) PHASE="${arg#phase=}" ;;
      arm=noread|arm=read|arm=residency) ARM="${arg#arm=}" ;;
      reboot=*) REBOOT="${arg#reboot=}" ;;
      dmg=nightly|dmg=https://*|dmg=sha256:*) dmg="${arg#dmg=}" ;;
      *) bad "unknown argument: $arg (takes phase=before|after arm=noread|read|residency reboot=N dmg=nightly|URL|sha256:HEX)" ;;
    esac
  done
  [[ -n "$PHASE" ]] || bad "phase=before or phase=after is required"
  [[ "$REBOOT" =~ ^[1-9][0-9]?$ ]] || bad "reboot= takes 1 to 99"
  [[ "$PHASE" == before || -n "$ARM" ]] || bad "phase=after needs arm=noread, arm=read or arm=residency"
  [[ "$PHASE" == after || -z "$ARM" ]] || bad "arm= is for phase=after"
  if [[ "$PHASE" == after ]]; then
    # First thing: a host the before step's reboot has not reached yet; then when the step started, against boot and
    # login.
    local was
    was="$(cat "$ROOT/before.boot" 2>/dev/null)"
    [[ -z "$was" || "$(boot_time)" != "$was" ]] || fail "not rebooted: kern.boottime is still the before step's ($was)"
    login_times
    after
  else
    before "$dmg"
  fi
}

bad() { echo "LB-FAIL bad argument: $1"; exit 2; }
fail() { echo "LB-FAIL reboot=${REBOOT:-?} $1"; exit 3; }

before() {
  echo "LB host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) root=$ROOT"
  sudo -n -l /sbin/shutdown -r now >/dev/null 2>&1 || fail "no passwordless sudo for /sbin/shutdown -r now"
  { mkdir -p "$ROOT/copy" "$ROOT/home" && chmod 0777 "$ROOT" "$ROOT/home"; } || fail "cannot make $ROOT"
  xcrun swiftc -O -o "$PROBE" scripts/measure/launch-premain.swift >"$ROOT/swiftc.log" 2>&1 \
    || { cat "$ROOT/swiftc.log"; fail "probe build failed"; }
  APP="$(find_app)"
  local installed=kept
  if [[ -z "$APP" || "$REBOOT" == 1 ]]; then
    # A new series (reboot=1) starts from the newest DMG; every later reboot launches the same copy.
    [[ -n "$APP" ]] && rm -rf "$APP"
    mkdir -p "$ROOT/mnt" || fail "cannot make $ROOT/mnt"
    fetch_dmg "$1" "$ROOT/app.dmg" || fail "no DMG"
    APP="$(copy_app "$ROOT/app.dmg" "$ROOT/mnt" "$ROOT/copy")" || fail "copy from the DMG failed"
    rm -f "$ROOT/app.dmg"
    installed=new
  fi
  binaries
  local f sizes=""
  for f in ${FILES[@]+"${FILES[@]}"}; do sizes="$sizes $(short "$f")_bytes=$(bytes "$f")"; done
  echo "LB-COPY reboot=$REBOOT installed=$installed version=$(plist CFBundleShortVersionString)-$(plist CFBundleVersion)$sizes path=\"$APP\""
  guard_bundle
  # Launched once since its install (its first-exec check paid), then quit with Keep Sessions and gone.
  local line
  line="$(run_open prime)"
  echo "LB-PRIME reboot=$REBOOT window_on_screen=$(field window_on_screen "$line") main_start=$(field main_start "$line")$(err "$line")"
  [[ -n "$(field window_on_screen "$line")" && "$(field window_on_screen "$line")" != null ]] || fail "the priming launch showed no window"
  ended
  boot_time >"$ROOT/before.boot" || fail "cannot write $ROOT/before.boot"
  echo "LB-REBOOT reboot=$REBOOT left=$(left | wc -l | tr -d ' ') in_s=${LB_REBOOT_DELAY:-20}"
  reboot_later
}

boot_time() { sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\),.*/\1/p'; }

# reboot_later: `sudo -n /sbin/shutdown -r now` LB_REBOOT_DELAY s (default 20) from now, in a new session with no
# terminal or pipes, so this step exits 0 and its worker reports it before the host goes down, and the end of the
# step's process group does not take the reboot with it (nohup alone when there is no perl). The before step has
# already checked the sudo rule.
reboot_later() {
  local later=(/bin/sh -c "sleep ${LB_REBOOT_DELAY:-20}; exec sudo -n /sbin/shutdown -r now")
  if command -v perl >/dev/null; then
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "${later[@]}" </dev/null >/dev/null 2>&1 &
  else
    nohup "${later[@]}" </dev/null >/dev/null 2>&1 &
  fi
  disown
}

after() {
  [[ -x "$PROBE" ]] || fail "no probe at $PROBE: run phase=before first"
  APP="$(find_app)"
  [[ -n "$APP" ]] || fail "no copy in $ROOT/copy: run phase=before first"
  binaries
  guard_bundle
  case "$ARM" in
    noread) at 60 launch ;;
    read) at 5 read; read_all; at 60 launch ;;
    residency)
      at 5 read; read_all
      at 60 +1m; resident_all +1m
      at 600 +10m; resident_all +10m
      at 3600 +60m; resident_all +60m ;;
  esac
  measured_launch
}

# login_times: LOGIN (epoch s) from the youngest loginwindow process's age, else kern.boottime; one LB-LOGIN row.
login_times() {
  local now boot age dock source=loginwindow
  now="$(date +%s)"
  boot="$(sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\),.*/\1/p')"
  age="$(age_of loginwindow)"
  dock="$(age_of Dock)"
  if [[ -n "$age" ]]; then LOGIN=$((now - age)); elif [[ -n "$boot" ]]; then LOGIN="$boot" source=boot; else fail "no kern.boottime and no loginwindow"; fi
  echo "LB-LOGIN reboot=$REBOOT arm=$ARM source=$source s_since_login=$((now - LOGIN)) s_since_boot=$([[ -n "$boot" ]] && echo $((now - boot))) login_after_boot_s=$([[ -n "$boot" ]] && echo $((LOGIN - boot))) s_since_dock=${dock}"
}

# age_of NAME: seconds since the youngest process named NAME started (ps etime: [[dd-]hh:]mm:ss), or nothing.
age_of() {
  ps -axo etime=,comm= | awk -v want="$1" '{ n = $NF; sub(".*/", "", n); if (n != want) next
    d = 0; t = $1; if (index(t, "-")) { split(t, p, "-"); d = p[1]; t = p[2] }
    k = split(t, f, ":"); s = 0; for (i = 1; i <= k; i++) s = s * 60 + f[i]; s += d * 86400
    if (best == "" || s < best) best = s }
    END { if (best != "") print best }'
}

since() { echo $(($(date +%s) - LOGIN)); }

# at OFFSET WHAT: wait until login + OFFSET seconds; LB-LATE when that time has already passed.
at() {
  local wait=$((LOGIN + $1 - $(date +%s)))
  if ((wait > 0)); then sleep "$wait"; else echo "LB-LATE reboot=$REBOOT arm=$ARM what=$2 target_s=$1 s_since_login=$(since)"; fi
}

find_app() { find "$ROOT/copy" -maxdepth 1 -name '*.app' 2>/dev/null | head -1; }
plist() { "$PLISTBUDDY" -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
bytes() { stat -L -f %z "$1"; }
# short FILE: the binary's name with no spaces (Chromium_Embedded_Framework), for k=v rows.
short() { basename "$1" | tr ' ' _; }
err() { local e; e="$(sed -n 's/.*"error":"\([^"]*\)".*/\1/p' <<<"$1")"; [[ -n "$e" ]] && echo " error=\"$e\""; }

# binaries: FILES, the executable and the two frameworks' binaries the copy has.
binaries() {
  local exe name f
  exe="$(plist CFBundleExecutable)"
  [[ -n "$exe" && -f "$APP/Contents/MacOS/$exe" ]] || fail "the copy has no executable: $APP"
  FILES=("$APP/Contents/MacOS/$exe")
  for name in CmuxNextApp "Chromium Embedded Framework"; do
    f="$APP/Contents/Frameworks/$name.framework/Versions/A/$name"
    [[ -f "$f" ]] && FILES+=("$f")
  done
}

guard_bundle() {
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || fail "a signing keychain is present"
}

# read_all: each binary through `time -l cat FILE >/dev/null`; wall from "real", cpu from user + sys, maxrss in bytes.
read_all() {
  local f out
  for f in ${FILES[@]+"${FILES[@]}"}; do
    out="$("$TIME_BIN" -l cat "$f" 2>&1 >/dev/null)"
    echo "LB-READ reboot=$REBOOT arm=$ARM s_since_login=$(since) file=$(short "$f") bytes=$(bytes "$f") $(awk '
      / real / { wall = $1 * 1000; cpu = ($3 + $5) * 1000 }
      /maximum resident set size/ { rss = $1 }
      END { printf "wall_ms=%d cpu_ms=%d maxrss=%s", wall + 0.5, cpu + 0.5, (rss == "" ? "null" : rss) }' <<<"$out")"
  done
}

# resident_all T: each binary's resident fraction (launch-premain's mincore reader, which faults nothing in).
resident_all() {
  local f r
  for f in ${FILES[@]+"${FILES[@]}"}; do
    r="$("$PROBE" resident "$f" 2>/dev/null)"
    echo "LB-RESIDENT reboot=$REBOOT arm=$ARM t=$1 s_since_login=$(since) file=$(short "$f") $(awk '
      $1 == "LP-RESIDENT" && NF == 4 { printf "resident_pct=%.1f resident_pages=%d pages=%d", $2 * 100, $3, $4; ok = 1 }
      END { if (!ok) printf "resident_pct=null" }' <<<"$r")"
  done
}

# run_open LABEL: one Dock-style open of the copy, in the console session, kept 6 s past its window, ended with
# SIGTERM ("Quit, keep sessions"); prints the probe's LP-RUN line.
run_open() {
  quiesce 0
  GITHUB_WORKSPACE="$PWD" "$CONSOLE" "$PROBE" open "$APP" "$ROOT/home" "$1" 6 term 2>>"$ROOT/probe.log" | grep '^LP-RUN '
}

# field KEY LINE: KEY's value in the probe's one-line JSON (sorted keys, numbers or null).
field() { sed -n "s/.*\"$1\":\([^,}]*\).*/\1/p" <<<"$2"; }

measured_launch() {
  resident_all prelaunch
  local s before after line cpu settle
  s="$(since)"
  before="$(checker_cpu)"
  line="$(run_open B)"
  after="$(checker_cpu)"
  echo "$line" >>"$ROOT/runs-$REBOOT-$ARM.jsonl"
  cpu="$(awk -v b="$before" -v a="$after" 'BEGIN { n = split(b, x, " "); split(a, y, " ")
    for (i = 1; i <= n; i++) { split(x[i], p, "="); split(y[i], q, "="); printf " %s_ms=%d", p[1], q[2] - p[2] } }')"
  settle="$(awk -v u="$(field window_usable "$line")" -v w="$(field window_on_screen "$line")" 'BEGIN {
    if (u != "" && u != "null") print u " settle_by=window_usable"
    else if (w != "" && w != "null") print w + 6000 " settle_by=window+6s"
    else print "null settle_by=none" }')"
  echo "LB-LAUNCH arm=$ARM reboot=$REBOOT s_since_login=$s request_to_start=$(val request_to_start "$line") main_start=$(val main_start "$line") first_frame=$(val first_window_frame_committed "$line") window_on_screen=$(val window_on_screen "$line") settle=$settle pageins=$(val pageins "$line")$cpu$(err "$line")"
  ended
  [[ -n "$line" ]] || fail "the measured launch printed no row"
  [[ "$(field window_on_screen "$line")" =~ ^[0-9] ]] || fail "the measured launch showed no window"
}

val() { local v; v="$(field "$1" "$2")"; echo "${v:-null}"; }

# left: the processes started from the copy (the app, its helpers, the daemons a quit keeps).
left() { ps -axo pid=,command= | LB_COPY="$ROOT/copy/" awk 'index($0, ENVIRON["LB_COPY"]) { print $1 }'; }

# ended: the app and its helpers gone (launch-premain's quiesce), then whatever of the copy is left ended by pid. They
# run as the console user, who may not be the step's user.
ended() {
  quiesce 0
  local pids; pids="$(left)"
  # shellcheck disable=SC2086 # one pid per word
  [[ -n "$pids" ]] && { sudo -n kill $pids 2>/dev/null || kill $pids 2>/dev/null; }
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit $?; fi
