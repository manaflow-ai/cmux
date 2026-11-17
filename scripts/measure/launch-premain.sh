#!/usr/bin/env bash
# What makes a cmux NEXT launch reach `main` 600 to 1170 ms late (CMUX-629): run 5 of the pre-main study, on a fleet
# Mac's console session, one copy of the NIGHTLY and one home:
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-premain.sh --ref <sha> [--arg=dmg=nightly|URL] [--arg=reps=5] \
#     [--arg=arms=h,a,b,c,g,d,k,e,e2,x,f,t1,t3,t6] --artifact .build/launch-premain/report.tgz --timeout 5400
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
set -uo pipefail

main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out="$PWD/.build/launch-premain" dmg=nightly reps=5 arms="h,a,b,c,g,d,k,e,e2,x,f,t1,t3,t6" arg rc=0 rep arm
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=https://*) dmg="${arg#dmg=}" ;;
      reps=*) reps="${arg#reps=}" ;;
      arms=*) arms="${arg#arms=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$reps" =~ ^([1-9]|1[0-2])$ ]] || { echo "reps= must be 1 to 12" >&2; exit 2; }
  [[ "$arms" =~ ^(h|a|b|c|g|d|k|e|e2|x|f|t1|t3|t6)(,(h|a|b|c|g|d|k|e|e2|x|f|t1|t3|t6))*$ ]] || { echo "arms= takes h,a,b,c,g,d,k,e,e2,x,f,t1,t3,t6" >&2; exit 2; }
  echo "LP host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  sudo -n true 2>/dev/null && echo "LP root yes" || echo "LP root no (arms d and f need it: their rows say so)"
  xcrun swiftc -O -o "$out/launch-premain" scripts/measure/launch-premain.swift >"$out/swiftc.log" 2>&1 \
    || { echo "LP probe build failed"; cat "$out/swiftc.log"; exit 3; }
  if [[ "$dmg" == nightly ]]; then
    dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
      | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  fi
  [[ "$dmg" == https://* ]] || { echo "LP no nightly DMG in the feed"; exit 3; }
  echo "LP dmg $dmg"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-premain/1 -o "$out/app.dmg" "$dmg" || { echo "LP download failed"; exit 3; }
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  local mount="$out/mnt" found
  mkdir -p "$mount" "$out/copy" "$out/home" && chmod 0777 "$out/home"
  hdiutil attach "$out/app.dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null || { echo "LP attach failed"; exit 3; }
  found="$(find "$mount" -maxdepth 1 -name '*.app' | head -1)"
  ditto "$found" "$out/copy/$(basename "$found")" || exit 3
  hdiutil detach "$mount" >/dev/null || hdiutil detach -force "$mount" >/dev/null
  APP="$out/copy/$(basename "$found")"
  EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
  STUB="$(find_stub "$APP")"
  # The app's code on a stub-executable build (cmux#44204): its link count and ctime are recorded beside the
  # executable's, so a run shows whether a scan moved onto it.
  FW="$APP/Contents/Frameworks/CmuxNextApp.framework/CmuxNextApp"
  [[ -e "$FW" ]] || FW=""
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
  python3 -I - "$out/runs.jsonl" <<'PY'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
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
    checkers = [r for r in rows if r["arm"] == arm and r.get("role") == "checkers"]
    for key in ("syspolicyd_ms", "xprotect_ms", "amfid_ms", "trustd_ms"):
        table[key] = med([r.get(key) for r in checkers])
    stubs = [r for r in rows if r["arm"] == arm and r.get("mode") == "stub"]
    if stubs:
        table["stub_wall_ms"] = med([r.get("wall_ms") for r in stubs])
    print("LP-TABLE", json.dumps(table), flush=True)
PY
  tar -czf "$out.tgz" -C "$out" --exclude '*.dmg' --exclude copy --exclude mnt --exclude home --exclude home-other . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
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
relink() { ln "$EXE" "$OUT/exe-link" && rm -f "$OUT/exe-link"; }

# measured open|exec|sampled: the measured launch B (open: SIGTERM at its first window), with the executable's link
# count and seconds since its ctime before it, and the CPU the system's code checkers (syspolicyd, XprotectService,
# amfid, trustd) spent across it, in ms.
measured() {
  local before after
  before="$(checker_cpu)"
  B_STATE="\"nlink\": $(stat -f %l "$EXE"), \"ctime_age_s\": $(($(date +%s) - $(stat -f %c "$EXE")))"
  [[ -n "$FW" ]] && B_STATE="$B_STATE, \"fw_nlink\": $(stat -L -f %l "$FW"), \"fw_ctime_age_s\": $(($(date +%s) - $(stat -L -f %c "$FW")))"
  case "$1" in
    open) launch open B 0 term ;;
    exec) launch exec B ;;
    sampled) sampled ;;
  esac
  local rc=$?
  after="$(checker_cpu)"
  record checkers "LP-RUN {$(awk -v b="$before" -v a="$after" 'BEGIN { n = split(b, x, " "); split(a, y, " ")
    for (i = 1; i <= n; i++) { split(x[i], p, "="); split(y[i], q, "="); printf "%s\"%s_ms\": %d", (i > 1 ? ", " : ""), p[1], q[2] - p[2] } }')}"
  B_STATE=""
  return $rc
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
  sudo -n true 2>/dev/null || return 0
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

# sampled: B exec'd suspended, `sample` attached (root, 1 ms interval), then let run to its main_start mark.
sampled() {
  local hold="$OUT/hold-$REP" log="$OUT/sampled-$REP.log" probe pid="" i sampler=""
  rm -f "$hold"
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$OUT/launch-premain" exec "$APP" "$OUT/home" B "$hold" >"$log" 2>>"$OUT/probe.log" &
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
