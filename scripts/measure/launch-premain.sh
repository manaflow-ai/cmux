#!/usr/bin/env bash
# What makes a cmux NEXT launch reach `main` 600 to 1170 ms late (CMUX-629): run 5 of the pre-main study, on a fleet
# Mac's console session, one copy of the NIGHTLY and one home:
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-premain.sh --ref <sha> [--arg=dmg=nightly|URL|sha256:HEX] [--arg=reps=5] \
#     [--arg=arms=h,a,b,c,g,d,k,e,e2,x,f,t1,t3,t6] [--arg=settle=1] --artifact .build/launch-premain/report.tgz --timeout 5400
# dmg=sha256:HEX is a DMG in the fleet's artifact store (`cmux-ci artifact-put FILE --sha256 HEX --lane W`): a build
# with no public URL, such as a pull request's signed candidate. The step is submitted with CMUX_WORKSPACE_ID=W, and the
# download is checked against HEX. Every run prints LP-GATE rows for the DMG and its app before the arms:
# `spctl --assess` (open for the DMG, exec for the app) and `stapler validate`, as Gatekeeper sees the copy it runs.
# Then one LP-LAYOUT row (bundle_layout: stub=yes|no, the executable's and the framework's size; layout.txt in the
# report has the ls -l, otool -L and codesign -dv it rests on).
# A launch reaches `main` in 30 to 80 ms when launches follow each other closely, and 600 to 1170 ms when about 60 s
# have passed since a full run began. Each arm is one pair (A, then the measured launch B), interleaved per rep, each
# pair started only while the Mac's 1-minute load is under 8. A and B are open (LaunchServices) launches, as the Dock
# opens; "short" ends one with SIGTERM at its first window, "60 s" keeps it 60 s and quits it as Cmd-Q does. B is
# short, measured 3 s after A ended:
#   h   A short; B                                                   (the fast condition)
#   a   A 60 s; B                                                    (the slow condition)
#   b   as a, and the executable is read (cat to /dev/null) right before B: fast means page cache
#   c   as a, and the smallest executable in the bundle is exec'd right before B (LP-RUN mode=stub times it)
#   g   A short, 60 s idle, B: time since a launch alone, with no long run
#   d   A short, then `purge` (root) before B: slow means evicted pages alone reproduce it (no root: no B)
#   k   A short, then `ln EXE x; rm x` before B: slow means a new link count and ctime alone make the system scan the
#       executable again, as Chromium's code-sign clone links it on every full run (cmux#44204)
#   t1, t3, t6  A kept 1, 3 or 6 s past its first window, quit as Cmd-Q does; B: at which point of a run the next
#       launch turns slow (a 6 s run and quit already does, launch-ready back to back), and B's nlink and ctime_age_s
#       say whether the executable was linked by then
#   e   our executable exec'd to main (X), Calculator opened and kept 60 s, quit, 3 s, B exec'd to main
#   e2  as e with 63 s of idle in place of Calculator (e's control)
#   x   as a, B exec'd to main (no LaunchServices)
#   f   as x, B started suspended under `sample` (root, 1 ms), so the 600 ms are attributed
# Rep 1 of arms a and h also records 8 s of fs_usage (disk I/O with PAGE_IN, file-system calls; root) across B.
# Every B also records the executable's link count and seconds since its ctime before it (role B), and the CPU
# syspolicyd, XprotectService, amfid and trustd spent across it (role checkers).
# Run 5 of the pre-main study as fable-startup-arch's run5.sh laid it out, in the repo so a fleet step can run it.
# Per launch: main_start (the app's mark, ms from process start), the process's pageins and user/system CPU at main,
# disk read, the executable's resident fraction before the launch and at main (pages_touched in exec mode: the
# process is stopped at its main_start mark). Prints LP-RUN per launch (with arm and rep), LP-TABLE at the end.
# settle=1 (default 0, which leaves every row and LP-TABLE as they were) lets each B run past main_start to its first
# frame and settle, and adds to B's row and to LP-TABLE (median, min, max per arm), in ms from process start:
# first_window_frame_committed, launch_shell.committed (null on a build without the mark), window_on_screen, and
# settle: window_usable, or window_on_screen + 6000 on a launch the app marked no window_usable for (settle_by, counted
# per arm in LP-TABLE). B waits for window_usable up to 15 s past its window; once a B ends with none and no B of the
# run has had one, the build has no such mark and every later B waits 6 s. That is up to 15 s more per B: give a
# full run with settle=1 a longer --timeout (7200). Per arm with settle=1:
#   h a b c g d k t1 t3 t6  B (open) is not ended with SIGTERM at its first window: it runs to window_usable (or the
#                            wait above) and is then ended with SIGTERM. A and everything before B are unchanged; in d,
#                            B still follows the purge.
#   e e2 x                   B (exec) is still stopped at main_start for the pre-main readings, then let run on to its
#                            window and settle, then SIGTERM; its marks after main include the stop (stopped_at_main_ms).
#   f                        as e, under `sample`: the sample still covers the first 5 s.
# The LP root line names which root commands sudo allows without a password (sudo -n -l per command: purge for arm d,
# fs_usage for the fs_usage record, sample for arm f), so a host whose sudoers allow only /usr/sbin/purge says so.
set -uo pipefail

# console CMD...: CMD in the console user's GUI session, as the app the probe opens runs (console-session.sh).
console() { GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$@"; }

# fresh_keychain HOME: a login keychain in a launch's empty home, as a person's home has, made as the console user.
# Without one, the app's Chromium makes "cmux Safe Storage" through a "Keychain Not Found" SecurityAgent panel nobody
# answers (left after launch-fresh-install on cmux12s; three from this script's arms h,a,d on cmux-austin-mini-1,
# 2026-11-18). CMUX_MOCK_KEYCHAIN is no way out: the app drops it from an inherited environment
# (fresh_home_launch_smoke.py login_keychain, which this follows). Every call has the home's own HOME and
# CFFIXED_USER_HOME, so the console user's own keychains and search list are untouched. Writes to $OUT/keychain.log.
fresh_keychain() {
  local home="$1" keychain="$1/Library/Keychains/login.keychain-db" step
  console /bin/mkdir -p "$home/Library/Keychains"
  for step in "create-keychain -p ''" "list-keychains -d user -s" "default-keychain -d user -s" "set-keychain-settings"; do
    console /usr/bin/env HOME="$home" CFFIXED_USER_HOME="$home" /bin/sh -c "exec /usr/bin/security $step \"\$0\"" "$keychain" \
      >>"$OUT/keychain.log" 2>&1 || { echo "LP keychain: security ${step%% *} failed in $home; a Keychain panel may show"; return 1; }
  done
}

# store_fetch HEX FILE: the fleet artifact store's object sha256:HEX into FILE, through the controller's signed URL
# (never printed), else its own GET; FILE must hash to HEX.
store_fetch() {
  local hex="$1" file="$2" controller="${CMUX_CI_CONTROLLER:-http://100.89.225.106:18765}" signed fetched=0
  signed="$(curl --fail --silent --connect-timeout 5 --max-time 30 -A cmux-launch-premain/1 \
    "${controller%/}/v1/artifacts/sha256:$hex/url" 2>/dev/null |
    /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("url", ""))' 2>/dev/null || true)"
  case "$signed" in https://*|http://*)
    curl --fail --silent --location --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 \
      -A cmux-launch-premain/1 -o "$file" "$signed" 2>/dev/null && fetched=1 ;;
  esac
  unset signed
  if (( ! fetched )); then
    curl --fail --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 900 \
      -A cmux-launch-premain/1 -o "$file" "${controller%/}/v1/artifacts/sha256:$hex" || return 1
  fi
  [[ "$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')" == "$hex" ]] || { echo "LP download is not sha256:$hex"; return 1; }
}

# gate WHAT TYPE PATH: one LP-GATE row each for `spctl --assess --type TYPE` and `stapler validate` of PATH, with the
# exit code and spctl's source line (a notarized Developer ID build reads "source=Notarized Developer ID"). A rejected
# gate is reported, not fatal: the arms still run.
gate() {
  local what="$1" type="$2" path="$3" text rc context=()
  [[ "$type" == open ]] && context=(--context context:primary-signature)
  text="$(spctl --assess --type "$type" ${context[@]+"${context[@]}"} -vv "$path" 2>&1)"; rc=$?
  echo "LP-GATE $what spctl rc=$rc $(printf '%s' "$text" | grep -E 'accepted|rejected|source=' | sed "s#$path#PATH#" | tr '\n' ' ')"
  text="$(xcrun stapler validate "$path" 2>&1)"; rc=$?
  echo "LP-GATE $what stapler rc=$rc $(printf '%s' "$text" | tail -1)"
}

# bundle_layout APP FILE PREFIX: which layout the measured build has, so every report says it and no reader infers it
# from the commit: FILE gets `ls -l` of Contents/MacOS and of CmuxNextApp.framework, `otool -L` of the main executable
# and `codesign -dv` of it and of the framework; one "PREFIX-LAYOUT" line says stub=yes when the main executable links
# CmuxNextApp.framework and the framework's binary is in the bundle (cmux#44204's stub layout), else stub=no.
bundle_layout() {
  local app="$1" file="$2" prefix="$3" exe fw links=no present=no
  exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  fw="$app/Contents/Frameworks/CmuxNextApp.framework/CmuxNextApp"
  {
    echo "== ls -l Contents/MacOS"; ls -l "$app/Contents/MacOS"
    echo "== ls -lL CmuxNextApp.framework"; ls -lL "$app/Contents/Frameworks/CmuxNextApp.framework" 2>&1
    echo "== otool -L $(basename "$exe")"; xcrun otool -L "$exe" 2>&1
    echo "== codesign -dv $(basename "$exe")"; codesign -dv "$exe" 2>&1
    echo "== codesign -dv CmuxNextApp.framework"; codesign -dv "$app/Contents/Frameworks/CmuxNextApp.framework" 2>&1
  } >"$file"
  xcrun otool -L "$exe" 2>/dev/null | grep -q 'CmuxNextApp\.framework/' && links=yes
  [[ -f "$fw" ]] && present=yes
  echo "$prefix-LAYOUT stub=$([[ $links == yes && $present == yes ]] && echo yes || echo no) exe_bytes=$(stat -f %z "$exe") links_framework=$links framework=$present framework_bytes=$([[ $present == yes ]] && stat -L -f %z "$fw") file=$(basename "$file")"
}

# fetch_dmg DMG FILE: DMG (nightly: the newest the NIGHTLY feed offers; https://...; sha256:HEX) downloaded into FILE,
# with its "LP dmg" line. Returns 2 for a malformed sha256:, 3 when nothing was downloaded (launch-reboot.sh uses it).
fetch_dmg() {
  local dmg="$1" file="$2"
  if [[ "$dmg" == nightly ]]; then
    dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
      | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  fi
  if [[ "$dmg" == sha256:* ]]; then
    [[ "$dmg" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "dmg=sha256: takes 64 lowercase hex" >&2; return 2; }
    echo "LP dmg $dmg"
    store_fetch "${dmg#sha256:}" "$file" || { echo "LP download failed"; return 3; }
  else
    [[ "$dmg" == https://* ]] || { echo "LP no nightly DMG in the feed"; return 3; }
    echo "LP dmg $dmg"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-premain/1 -o "$file" "$dmg" || { echo "LP download failed"; return 3; }
  fi
}

# copy_app DMG_FILE MOUNT DIR: the DMG's app copied (ditto) into DIR; prints the copy's path.
copy_app() {
  local found
  hdiutil attach "$1" -nobrowse -readonly -mountpoint "$2" >/dev/null || { echo "LP attach failed" >&2; return 3; }
  found="$(find "$2" -maxdepth 1 -name '*.app' | head -1)"
  ditto "$found" "$3/$(basename "$found")" || return 3
  hdiutil detach "$2" >/dev/null || hdiutil detach -force "$2" >/dev/null
  echo "$3/$(basename "$found")"
}

# parse_args ARG...: DMG, REPS, ARMS and SETTLE from the step's arguments; a bad one exits 2 before anything runs.
parse_args() {
  local arg
  DMG=nightly REPS=5 ARMS="h,a,b,c,g,d,k,e,e2,x,f,t1,t3,t6" SETTLE=0
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=https://*|dmg=sha256:*) DMG="${arg#dmg=}" ;;
      reps=*) REPS="${arg#reps=}" ;;
      arms=*) ARMS="${arg#arms=}" ;;
      settle=*) SETTLE="${arg#settle=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$REPS" =~ ^([1-9]|1[0-2])$ ]] || { echo "reps= must be 1 to 12" >&2; exit 2; }
  [[ "$ARMS" =~ ^(h|a|b|c|g|d|k|e|e2|x|f|t1|t3|t6)(,(h|a|b|c|g|d|k|e|e2|x|f|t1|t3|t6))*$ ]] || { echo "arms= takes h,a,b,c,g,d,k,e,e2,x,f,t1,t3,t6" >&2; exit 2; }
  [[ "$SETTLE" =~ ^[01]$ ]] || { echo "settle= takes 0 or 1" >&2; exit 2; }
  SETTLE_S=15
}

# root_check: the LP root line. Each root command a run uses is checked on its own with `sudo -n -l CMD` (true only
# when sudoers allow that command without a password), not `sudo -n true`, which a purge-only sudoers refuses.
root_check() {
  local name path allowed=() refused=()
  for name in purge:/usr/sbin/purge fs_usage:/usr/bin/fs_usage sample:/usr/bin/sample; do
    path="${name#*:}"
    if sudo -n -l "$path" >/dev/null 2>&1; then allowed+=("${name%%:*}"); else refused+=("${name%%:*}"); fi
  done
  local list="${allowed[*]:-}" none="${refused[*]:-}"
  if ((${#allowed[@]} == 0)); then
    echo "LP root no (arms d and f need it: their rows say so)"
  elif ((${#refused[@]} == 0)); then
    echo "LP root yes (allowed: ${list// /, })"
  else
    echo "LP root yes (allowed: ${list// /, }; refused: ${none// /, })"
  fi
}

main() {
  cd "$(dirname "$0")/../.." || exit 3
  parse_args "$@"
  local out="$PWD/.build/launch-premain" dmg="$DMG" reps="$REPS" arms="$ARMS" rc=0 rep arm
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  echo "LP host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  root_check
  ((SETTLE)) && echo "LP settle B runs to window_usable (at most ${SETTLE_S} s past its window) or window+6s"
  xcrun swiftc -O -o "$out/launch-premain" scripts/measure/launch-premain.swift >"$out/swiftc.log" 2>&1 \
    || { echo "LP probe build failed"; cat "$out/swiftc.log"; exit 3; }
  fetch_dmg "$dmg" "$out/app.dmg" || exit $?
  gate dmg open "$out/app.dmg"
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  mkdir -p "$out/mnt" "$out/copy" "$out/home" && chmod 0777 "$out/home"
  # The probe's home (launch-premain.swift's HOME_ROOT/h) gets a login keychain before any launch (fresh_keychain).
  OUT="$out" fresh_keychain "$out/home/h" || true
  APP="$(copy_app "$out/app.dmg" "$out/mnt" "$out/copy")" || exit 3
  gate app exec "$APP"
  bundle_layout "$APP" "$out/layout.txt" LP
  EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
  STUB="$(find_stub "$APP")"
  # The app's code on a stub-executable build (cmux#44204): its link count and ctime are recorded beside the
  # executable's, so a run shows whether a scan moved onto it.
  FW="$APP/Contents/Frameworks/CmuxNextApp.framework/CmuxNextApp"
  [[ -e "$FW" ]] || FW=""
  [[ -f "$APP/Contents/Info.plist" ]] || { echo "LP-FAIL $APP has no Contents/Info.plist"; exit 3; }
  echo "LP app $(basename "$APP") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null) exe_bytes=$(stat -f %z "$EXE") stub=${STUB#$APP/} stub_bytes=$([[ -n "$STUB" ]] && stat -f %z "$STUB") framework_bytes=$([[ -n "$FW" ]] && stat -L -f %z "$FW")"
  OUT="$out"
  # The copy's first exec pays its first-look cost (3.4 to 4.4 s, not this study's subject); the priming launch makes
  # the home's state, so every launch after it is a person's relaunch.
  # Two warm launches, as run5.sh made them: one ended with SIGTERM at its window, one quit after 10 s.
  launch open prime 0 term >/dev/null || rc=1
  launch open prime 10 quit >/dev/null || rc=1
  local list; IFS=, read -r -a list <<<"$arms"
  for ((rep = 1; rep <= reps; rep++)); do
    # Rotate the arm order per rep, so no arm always follows the same one.
    local n=${#list[@]} k
    for ((k = 0; k < n; k++)); do
      arm="${list[$(((k + rep - 1) % n))]}"
      wait_load "$arm" "$rep"
      pair "$arm" "$rep" || rc=1
    done
  done
  # Every process this run left (the daemons a quit keeps): only ones started from this run's copy. They run as the
  # console user, who may not be the step's user.
  local pids; pids="$(ps -axo pid=,command= | LP_ROOT="$out/" awk 'index($0, ENVIRON["LP_ROOT"]) { print $1 }')"
  [[ -n "$pids" ]] && { sudo -n kill $pids 2>/dev/null || kill $pids 2>/dev/null; }
  lp_table "$out/runs.jsonl" "$SETTLE"
  tar -czf "$out.tgz" -C "$out" --exclude '*.dmg' --exclude copy --exclude mnt --exclude home --exclude home-other . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# lp_table RUNS SETTLE: one LP-TABLE row per arm from RUNS (runs.jsonl): median, min and max of each B column, the
# checkers' CPU and the stub's wall time. SETTLE=1 adds the settle columns and settle_by counts.
lp_table() {
  python3 -I - "$1" "$2" <<'PY'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
settle = sys.argv[2] == "1"
def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    return {"median": round(statistics.median(vals), 1), "min": min(vals), "max": max(vals)} if vals else None
for arm in dict.fromkeys(r["arm"] for r in rows if r.get("role") == "B"):
    b = [r for r in rows if r["arm"] == arm and r.get("role") == "B" and r.get("main_start") is not None]
    table = {"arm": arm, "n": len(b)}
    for key in ("main_start", "pageins", "system_pageins", "user_ms", "system_ms", "disk_read_kb", "resident_before",
                "resident_at_main", "pages_touched", "fw_resident_before", "fw_resident_at_main", "fw_pages_touched",
                "fw_nlink", "fw_ctime_age_s"):
        table[key] = med([r.get(key) for r in b])
    for key in ("nlink", "ctime_age_s"):
        table[key] = med([r.get(key) for r in b])
    if settle:
        for key in ("first_window_frame_committed", "launch_shell.committed", "window_on_screen", "settle"):
            table[key] = med([r.get(key) for r in b])
        by = {}
        for r in b:
            by[r.get("settle_by", "none")] = by.get(r.get("settle_by", "none"), 0) + 1
        table["settle_by"] = by
    checkers = [r for r in rows if r["arm"] == arm and r.get("role") == "checkers"]
    for key in ("syspolicyd_ms", "xprotect_ms", "amfid_ms", "trustd_ms"):
        table[key] = med([r.get(key) for r in checkers])
    stubs = [r for r in rows if r["arm"] == arm and r.get("mode") == "stub"]
    if stubs:
        table["stub_wall_ms"] = med([r.get("wall_ms") for r in stubs])
    print("LP-TABLE", json.dumps(table), flush=True)
PY
}

# find_stub APP: the smallest Mach-O executable in APP over 100 KB (the 300 KB stub beside the 107 MB executable).
find_stub() {
  find "$1/Contents" -type f -perm -u+x -size +200 2>/dev/null | while read -r f; do
    file -b "$f" | grep -q 'Mach-O.*executable' && echo "$(stat -f %z "$f") $f"
  done | sort -n | head -1 | cut -d' ' -f2-
}

# launch MODE ROLE ARGS...: one probe run in the console session; the LP-RUN line, with arm, rep and role, goes to
# stdout and runs.jsonl. MODE open takes RUN_S; exec takes [HOLD].
launch() {
  local mode="$1" role="$2" line
  shift 2
  if [[ "$mode" == open ]]; then
    quiesce 0
    line="$(GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$OUT/launch-premain" open "$APP" "$OUT/home" "$role" "$1" "${2:-quit}" 2>>"$OUT/probe.log" | grep '^LP-RUN ')"
  else
    line="$(GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$OUT/launch-premain" exec "$APP" "$OUT/home" "$role" "$@" 2>>"$OUT/probe.log" | grep '^LP-RUN ')"
  fi
  record "$role" "$line"
}

# record ROLE LINE: LINE's JSON with arm, rep, role and the 1-minute load added, to stdout and runs.jsonl.
record() {
  local role="$1" line="$2" json
  [[ -n "$line" ]] || line="LP-RUN {\"error\": \"no result\"}"
  json="$(echo "${line#LP-RUN }" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); r.update(json.loads("{" + sys.argv[5] + "}")); r.update(arm=sys.argv[1], rep=int(sys.argv[2]), role=sys.argv[3], load=float(sys.argv[4])); print(json.dumps(r, sort_keys=True))' "${ARM:-prime}" "${REP:-0}" "$role" "$(load1)" "$([[ "$role" == B ]] && echo "${B_STATE:-}")")"
  echo "LP-RUN $json"
  echo "$json" >>"$OUT/runs.jsonl"
  [[ "$json" != *'"error"'* ]]
}

# pair ARM REP: one A then B of ARM. `ended` is A's end to B: the copy's helpers gone, then 3 s.
pair() {
  ARM="$1" REP="$2"
  quiesce 2
  case "$ARM" in
    h) launch open A 0 term && ended && fsrec h && measured open ;;
    a) launch open A 60 quit && ended && fsrec a && measured open ;;
    b) launch open A 60 quit && ended && cat "$EXE" >/dev/null && measured open ;;
    c) launch open A 60 quit && ended && stub && measured open ;;
    g) launch open A 0 term && quiesce 0 && sleep 60 && measured open ;;
    d) launch open A 0 term && quiesce 0 && root /usr/sbin/purge && sleep 3 && measured open ;;
    k) launch open A 0 term && ended && relink && measured open ;;
    t1|t3|t6) launch open A "${ARM#t}" quit && ended && measured open ;;
    e) launch exec X && other_app 60 && sleep 3 && measured exec ;;
    e2) launch exec X && sleep 63 && measured exec ;;
    x) launch open A 60 quit && ended && measured exec ;;
    f) launch open A 60 quit && ended && measured sampled ;;
  esac
}

ended() { quiesce 0; sleep 3; }

# relink: a second hard link to the executable made and removed, as Chromium's code-sign clone links it into
# $DARWIN_USER_TEMP/../X/<bundle id>.code_sign_clone/ (cmux#44204): the link count and ctime change, the bytes do not.
# First as the step's user; if that is refused, as the console user the app runs as (Chromium links as the app). A row
# (role relink) says who made the link, or both errors.
relink() {
  local direct console="" by=step nlink
  nlink="$(stat -f %l "$EXE")"
  if ! direct="$(ln "$EXE" "$OUT/exe-link" 2>&1)"; then
    rm -f "$OUT/home/exe-link"
    if console="$(GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh /bin/sh -c \
        'ln "$1" "$2" && rm -f "$2"' sh "$EXE" "$OUT/home/exe-link" 2>&1 >/dev/null)"; then
      by=console
    else
      by=none
    fi
  fi
  rm -f "$OUT/exe-link"
  record relink "LP-RUN $(python3 -I -c 'import json,sys; print(json.dumps({"relink_by": sys.argv[1], "nlink_before": int(sys.argv[2]), "nlink_after": int(sys.argv[3]), "direct_error": sys.argv[4][-300:], "console_error": sys.argv[5][-300:]}))' \
    "$by" "$nlink" "$(stat -f %l "$EXE")" "$direct" "$console")"
  [[ "$by" != none ]]
}

# measured open|exec|sampled: the measured launch B (open: SIGTERM at its first window; settle=1: at its settle, as
# the header says), with the executable's link count and seconds since its ctime before it, and the CPU the system's
# code checkers (syspolicyd, XprotectService, amfid, trustd) spent across it, in ms.
measured() {
  local before after
  before="$(checker_cpu)"
  B_STATE="\"nlink\": $(stat -f %l "$EXE"), \"ctime_age_s\": $(($(date +%s) - $(stat -f %c "$EXE")))"
  [[ -n "$FW" ]] && B_STATE="$B_STATE, \"fw_nlink\": $(stat -L -f %l "$FW"), \"fw_ctime_age_s\": $(($(date +%s) - $(stat -L -f %c "$FW")))"
  if ((${SETTLE:-0})); then
    case "$1" in
      open) launch open B "$SETTLE_S" settle ;;
      exec) launch exec B "settle=$SETTLE_S" ;;
      sampled) sampled ;;
    esac
  else
    case "$1" in
      open) launch open B 0 term ;;
      exec) launch exec B ;;
      sampled) sampled ;;
    esac
  fi
  local rc=$?
  ((${SETTLE:-0})) && settle_wait
  after="$(checker_cpu)"
  record checkers "LP-RUN {$(awk -v b="$before" -v a="$after" 'BEGIN { n = split(b, x, " "); split(a, y, " ")
    for (i = 1; i <= n; i++) { split(x[i], p, "="); split(y[i], q, "="); printf "%s\"%s_ms\": %d", (i > 1 ? ", " : ""), p[1], q[2] - p[2] } }')}"
  B_STATE=""
  return $rc
}

# settle_wait: once a settled B ended with no window_usable (settle_by window+6s) and no B of this run has marked
# one, the build has no such mark: later B wait 6 s past their window, not 15 (one LP settle line says so).
settle_wait() {
  ((SETTLE_S > 6)) || return 0
  grep -q '"settle_by": "window_usable"' "$OUT/runs.jsonl" 2>/dev/null && return 0
  grep -q '"settle_by": "window+6s"' "$OUT/runs.jsonl" 2>/dev/null || return 0
  SETTLE_S=6
  echo "LP settle: no window_usable from this build in 15 s past its window; later B wait 6 s (settle_by window+6s)"
}

# checker_cpu: cumulative CPU ms of syspolicyd, XprotectService, amfid and trustd ("name=ms" each; ps needs no root).
checker_cpu() {
  ps -axo time=,comm= | awk '{ n = $NF; sub(".*/", "", n); k = split($1, t, ":"); s = 0
    for (i = 1; i <= k; i++) s = s * 60 + t[i]
    ms = s * 1000
    if (n == "syspolicyd" || n == "XprotectService" || n == "amfid" || n == "trustd") c[n] += ms }
    END { printf "syspolicyd=%d xprotect=%d amfid=%d trustd=%d", c["syspolicyd"], c["XprotectService"], c["amfid"], c["trustd"] }'
}

# fsrec NAME: on rep 1, 8 s of fs_usage (disk I/O with PAGE_IN, file-system calls) into fs-NAME.txt, started 1 s
# before B (root; skipped without it).
fsrec() {
  [[ "$REP" == 1 ]] || return 0
  sudo -n -l /usr/bin/fs_usage >/dev/null 2>&1 || return 0
  sudo -n /usr/bin/fs_usage -w -t 8 -f diskio -f filesys >"$OUT/fs-$1.txt" 2>&1 &
  sleep 1
}

# stub: the bundle's smallest executable, exec'd and timed to exit, in the console session.
stub() {
  [[ -n "$STUB" ]] || { record stub 'LP-RUN {"error": "no stub in the bundle", "mode": "stub"}'; return 0; }
  record stub "$(GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$OUT/launch-premain" stub "$STUB" stub 2>>"$OUT/probe.log" | grep '^LP-RUN ')"
  return 0
}

# root CMD...: CMD as root, or a row that says it could not run (the pair then measures no B).
root() {
  if sudo -n "$@" >>"$OUT/root.log" 2>&1; then return 0; fi
  record root "LP-RUN {\"error\": \"sudo -n $1 refused\"}"
  return 1
}

# other_app SECONDS: Calculator opened through the same probe, kept SECONDS, quit as Cmd-Q quits (its row: role other).
other_app() {
  mkdir -p "$OUT/home-other" && chmod 0777 "$OUT/home-other"
  record other "$(GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$OUT/launch-premain" open /System/Applications/Calculator.app "$OUT/home-other" other "$1" 2>>"$OUT/probe.log" | grep '^LP-RUN ')"
  return 0
}

# sampled: B exec'd suspended, `sample` attached (root, 1 ms interval), then let run to its main_start mark (settle=1:
# on to its settle).
sampled() {
  local hold="$OUT/hold-$REP" log="$OUT/sampled-$REP.log" probe pid="" i sampler="" settle=()
  rm -f "$hold"
  ((${SETTLE:-0})) && settle=("settle=$SETTLE_S")
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$OUT/launch-premain" exec "$APP" "$OUT/home" B "$hold" \
    ${settle[@]+"${settle[@]}"} >"$log" 2>>"$OUT/probe.log" &
  probe=$!
  for ((i = 0; i < 300; i++)); do pid="$(sed -n 's/^LP-PID //p' "$log")"; [[ -n "$pid" ]] && break; sleep 0.05; done
  if [[ -n "$pid" ]]; then
    sudo -n /usr/bin/sample "$pid" 5 1 -mayDie -file "$OUT/sample-$REP.txt" >>"$OUT/root.log" 2>&1 &
    sampler=$!
    sleep 1.5 # sample's own attach (a measurement script, not runtime code)
  fi
  touch "$hold" && chmod 0666 "$hold"
  wait "$probe"
  [[ -n "$sampler" ]] && wait "$sampler"
  record B "$(grep '^LP-RUN ' "$log")"
}

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }

# wait_load ARM REP: a pair starts only while the 1-minute load is under 8 (at most 10 min of waiting, then it runs and
# its rows carry the load).
wait_load() {
  local i
  for ((i = 0; i < 120; i++)); do
    awk -v l="$(load1)" 'BEGIN { exit !(l < 8) }' && return 0
    sleep 5
  done
  echo "LP load $(load1) still over 8 before $1 rep $2"
}

# quiesce SETTLE: wait until no process of the copy's previous run is left (the app and its helpers, not the daemons in
# Contents/Resources/bin a quit keeps), at most 60 s, then SETTLE seconds.
quiesce() {
  local i
  for ((i = 0; i < 600; i++)); do
    [[ "$(ps -axo command= | LP_MACOS="$APP/Contents/MacOS/" LP_FRAMEWORKS="$APP/Contents/Frameworks/" \
      awk 'index($0, ENVIRON["LP_MACOS"]) || index($0, ENVIRON["LP_FRAMEWORKS"]) { n++ } END { print n + 0 }')" == 0 ]] && break
    sleep 0.1
  done
  sleep "$1"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit $?; fi
