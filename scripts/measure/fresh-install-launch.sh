#!/usr/bin/env bash
# A new user's first launch of cmux NEXT, from a downloaded DMG (CMUX-629; Leo, 2026-11-17: "the whole point is a
# fresh launch somebody installing and launching from scratch"), and the other launches of the startup matrix with the
# same probe and clock. Run as root on a fleet Mac with a logged-in console user (the probe hops into its Aqua session):
#   fleet-sudo HOST bash scripts/measure/fresh-install-launch.sh [app=NAME=URL]... [mode=...] [runs=5] [load=0] [purge=...]
# or on the measurement queue:
#   cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/fresh-install-launch.sh \
#     --ref <sha> --arg=app=nightly --arg=app=rex=https://... --arg=runs=5 --artifact .build/fresh-install-launch/report.tgz
#   app=nightly        the newest NIGHTLY the feed offers; app=NAME=https://...dmg any DMG (repeatable: the apps' runs
#                      interleave, app 1 run 1, app 2 run 1, ...). Default: app=nightly
#   mode=fresh-install (default) each run: the DMG downloaded as a browser leaves it (com.apple.quarantine, Safari's
#                      flag 0083 with a new time and UUID), mounted, its app copied to /Applications as a drag does,
#                      the image ejected, then opened through LaunchServices with an empty home: Gatekeeper's
#                      first-launch assessment, its dialog (pressed Open by the probe, its dwell reported apart) and the
#                      app's first run (onboarding) all count
#   mode=cold-relaunch the app installed and approved once, then each run its second-and-later launch (the same copy, the
#                      same home) right after the disk cache is purged: a launch after a reboot, short of the reboot
#   mode=warm-relaunch the same, without the purge: a person's next launch
#   runs=N             runs per app (1 to 20, default 5)
#   load=N             N busy processes for the whole run (a loaded Mac like Leo's: load average about N); default 0
#   purge=before-launch (default) `purge` right before each open: the disk cache is cold for the launch (the DMG's
#                      copy would have warmed it). purge=before-install: before the download only. purge=none
# The probe (fresh-install-launch.swift) prints FIL-RUN per launch; this prints FIL-LOG (syspolicyd, XProtect, amfid,
# trustd, lsd: the unified log between the open and the window, counted per process with its first and last line's
# time), FIL-INSTALL (download, mount, copy and eject seconds, the quarantine the copy carries) and FIL-SUMMARY per app
# (median and p95 of each column). report.tgz keeps runs.jsonl and the logs.
set -uo pipefail

main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out="$PWD/.build/fresh-install-launch" mode=fresh-install runs=5 load=0 purge=before-launch arg apps=() rc=0
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  for arg in "$@"; do
    case "$arg" in
      app=nightly) apps+=("nightly=nightly") ;;
      app=*=https://*) apps+=("${arg#app=}") ;;
      mode=fresh-install|mode=cold-relaunch|mode=warm-relaunch) mode="${arg#mode=}" ;;
      runs=*) runs="${arg#runs=}" ;;
      load=*) load="${arg#load=}" ;;
      purge=before-launch|purge=before-install|purge=none) purge="${arg#purge=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ ${#apps[@]} -gt 0 ]] || apps=("nightly=nightly")
  [[ "$runs" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "runs= must be 1 to 20" >&2; exit 2; }
  [[ "$load" =~ ^[0-9]+$ && "$load" -le 256 ]] || { echo "load= must be 0 to 256" >&2; exit 2; }
  [[ "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || { echo "FIL needs root or passwordless sudo (purge, the console hop)" >&2; exit 3; }
  CONSOLE_USER="$(stat -f %Su /dev/console)"
  [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != root && "$CONSOLE_USER" != loginwindow ]] || { echo "FIL no console user" >&2; exit 3; }
  chown "$CONSOLE_USER" "$out" 2>/dev/null
  echo "FIL host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" mem=$(( $(sysctl -n hw.memsize) / 1073741824 ))G macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) console=$CONSOLE_USER mode=$mode runs=$runs load=$load purge=$purge"
  echo "FIL xprotect $(defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist CFBundleShortVersionString 2>/dev/null) uptime=\"$(uptime | sed 's/^ *//')\""
  as_user xcrun swiftc -O -o "$out/probe" scripts/measure/fresh-install-launch.swift >"$out/swiftc.log" 2>&1 \
    || { echo "FIL probe build failed"; cat "$out/swiftc.log"; exit 3; }
  cp scripts/ci/frame-pacing/console-session.sh "$out/console-session.sh"
  write_approver "$out/approve.sh"
  # Each app's DMG, downloaded once; every run starts from its own copy of these bytes with a new quarantine.
  local entry name url i
  for entry in "${apps[@]}"; do
    name="${entry%%=*}" url="${entry#*=}"
    if [[ "$url" == nightly ]]; then
      url="$(curl -fsSL --proto '=https' --retry 3 -H 'Cache-Control: no-cache' https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
        | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
    fi
    [[ "$url" == https://* ]] || { echo "FIL $name: no DMG URL"; exit 3; }
    local started=$SECONDS
    as_user curl -fsSL --proto '=https' --retry 3 -A "Mozilla/5.0 (Macintosh) fresh-install-launch/1" -o "$out/$name.dmg" "$url" \
      || { echo "FIL $name: download failed"; exit 3; }
    echo "FIL dmg $name $url $(( $(stat -f %z "$out/$name.dmg") / 1048576 )) MiB in $((SECONDS - started)) s"
  done
  local loaders=()
  if [[ "$load" -gt 0 ]]; then
    for ((i = 0; i < load; i++)); do nice -n 0 yes >/dev/null & loaders+=($!); done
    trap 'kill ${loaders[*]} 2>/dev/null' EXIT
    sleep 20 # the load average climbs toward N
    echo "FIL load $load processes; $(sysctl -n vm.loadavg)"
  fi
  if [[ "$mode" != fresh-install ]]; then
    for entry in "${apps[@]}"; do
      name="${entry%%=*}"
      install "$out" "$name" prime || exit 3
      launch "$out" "$name" prime || { echo "FIL $name: the priming launch failed"; rc=1; }
    done
  fi
  for ((i = 1; i <= runs; i++)); do
    for entry in "${apps[@]}"; do
      name="${entry%%=*}"
      if [[ "$mode" == fresh-install ]]; then
        [[ "$purge" == before-install ]] && do_purge "$name" "run$i"
        install "$out" "$name" "run$i" || { rc=1; continue; }
      fi
      [[ "$purge" == before-launch && "$mode" != warm-relaunch ]] && do_purge "$name" "run$i"
      launch "$out" "$name" "run$i" || rc=1
      [[ "$mode" == fresh-install ]] && uninstall "$out" "$name"
    done
  done
  [[ "$mode" != fresh-install ]] && for entry in "${apps[@]}"; do uninstall "$out" "${entry%%=*}"; done
  [[ ${#loaders[@]} -gt 0 ]] && kill "${loaders[@]}" 2>/dev/null
  summarize "$out/runs.jsonl"
  tar -czf "$out.tgz" -C "$out" --exclude '*.dmg' --exclude '*.app' --exclude probe . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

as_user() { if [[ "$(id -un)" == "$CONSOLE_USER" ]]; then "$@"; else sudo -n -u "$CONSOLE_USER" "$@"; fi; }
do_purge() { local t=$SECONDS; sudo -n purge; echo "FIL purge $1 $2 $((SECONDS - t)) s"; }

# install OUT NAME LABEL: the browser's download (a new copy of the DMG's bytes with Safari's quarantine), the mount,
# the drag to /Applications and the eject, as the console user. The copy's path goes to OUT/NAME.installed.
install() {
  local out="$1" name="$2" label="$3" dmg="$out/$name-$label.dmg" mnt="$out/mnt-$name-$label" t0 t1 t2 t3 found dest q how
  as_user cp "$out/$name.dmg" "$dmg" || return 1
  q="$(printf '0083;%x;Safari;%s' "$(date +%s)" "$(uuidgen)")"
  as_user xattr -w com.apple.quarantine "$q" "$dmg" || return 1
  t0=$(ms)
  as_user mkdir -p "$mnt"
  as_user hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null || { echo "FIL $name $label: attach failed"; return 1; }
  t1=$(ms)
  found="$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)"
  dest="/Applications/$(basename "$found")"
  # Never over a copy this run did not make: a host's own install stays; this run's goes beside it.
  [[ -e "$dest" ]] && dest="/Applications/$(basename "$found" .app) fil.app"
  [[ -e "$dest" ]] && { echo "FIL $name $label: $dest exists"; as_user hdiutil detach "$mnt" -force >/dev/null; return 1; }
  as_user ditto "$found" "$dest" || { as_user hdiutil detach "$mnt" -force >/dev/null; return 1; }
  t2=$(ms)
  as_user hdiutil detach "$mnt" >/dev/null || as_user hdiutil detach -force "$mnt" >/dev/null
  t3=$(ms)
  rm -f "$dmg"; rmdir "$mnt" 2>/dev/null
  local exe; exe="$dest/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$dest/Contents/Info.plist")"
  how=propagated
  if [[ "$(xattr -p com.apple.quarantine "$exe" 2>/dev/null)" != 008* ]]; then
    # A Finder drag out of a quarantined image quarantines every file; when this copy did not, the same flag goes on.
    as_user xattr -w -r com.apple.quarantine "$q" "$dest"; how=applied
  fi
  echo "$dest" >"$out/$name.installed"
  echo "FIL-INSTALL $name $label {\"mount_ms\":$((t1 - t0)),\"copy_ms\":$((t2 - t1)),\"eject_ms\":$((t3 - t2)),\"quarantine\":\"$(xattr -p com.apple.quarantine "$exe" 2>/dev/null)\",\"quarantine_how\":\"$how\",\"provenance\":\"$(xattr "$exe" 2>/dev/null | grep -c provenance)\",\"version\":\"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/Contents/Info.plist" 2>/dev/null) ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$dest/Contents/Info.plist" 2>/dev/null))\",\"bundle_mb\":$(du -sm "$dest" | cut -f1),\"path\":\"$dest\"}"
}

uninstall() {
  local dest; dest="$(cat "$1/$2.installed" 2>/dev/null)"
  [[ -n "$dest" && "$dest" == /Applications/*.app && -d "$dest" ]] || return 0
  # Only processes that run out of this run's copy (the app, its helpers and daemons), by pid.
  local pids; pids="$(ps -axo pid=,command= | awk -v p="$dest/" 'index($0, p) { print $1 }')"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null && sleep 2
  pids="$(ps -axo pid=,command= | awk -v p="$dest/" 'index($0, p) { print $1 }')"
  [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null
  rm -rf "$dest" "$1/$2.installed"
}

# launch OUT NAME LABEL: one probe run in the console session, its home OUT/home-NAME[-LABEL] (fresh-install: a new
# home each run; the relaunch modes: one home per app, made by the priming launch), then the unified log of its span.
launch() {
  local out="$1" name="$2" label="$3" app home line since until
  app="$(cat "$out/$name.installed")"
  home="$out/home-$name"; [[ "$mode" == fresh-install ]] && home="$out/home-$name-$label"
  as_user mkdir -p "$home"
  quiesce "$app"
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  line="$(GITHUB_WORKSPACE="$out" "$out/console-session.sh" "$out/probe" "$app" "$home" "$label" 3 "$out/approve.sh" 2>>"$out/probe.log" | grep '^FIL-RUN ')"
  until="$(date -v+1S '+%Y-%m-%d %H:%M:%S')"
  [[ -n "$line" ]] || { echo "FIL-RUN $name $label no result"; return 1; }
  echo "$line" | sed "s/^FIL-RUN /FIL-RUN $name /"
  local logfile="$out/log-$name-$label.txt"
  /usr/bin/log show --style compact --info --debug --start "$since" --end "$until" --predicate \
    'process == "syspolicyd" OR process == "XprotectService" OR process == "XProtect" OR process == "amfid" OR process == "trustd" OR process == "lsd" OR process == "CoreServicesUIAgent" OR subsystem BEGINSWITH "com.apple.syspolicy" OR subsystem == "com.apple.xprotect"' \
    >"$logfile" 2>/dev/null
  local logsum; logsum="$(python3 -I - "$logfile" "${line#FIL-RUN }" <<'PY'
import json, sys, time, datetime
row = json.loads(sys.argv[2]); t0 = row["request_epoch_ms"] / 1000
per = {}
for line in open(sys.argv[1], errors="replace"):
    parts = line.split()
    if len(parts) < 4 or not parts[0][:4].isdigit():
        continue
    try:
        ts = datetime.datetime.strptime(parts[0] + " " + parts[1][:15], "%Y-%m-%d %H:%M:%S.%f").timestamp()
    except ValueError:
        continue
    who = parts[3].split("[")[0].split(":")[0]
    rel = round((ts - t0) * 1000)
    if rel < -500:
        continue
    p = per.setdefault(who, {"n": 0, "first_ms": rel, "last_ms": rel})
    p["n"] += 1; p["last_ms"] = rel
    low = line.lower()
    for key in ("notariz", "ticket", "xprotect", "scan", "assess", "cloudkit"):
        if key in low:
            p.setdefault("words", {}).setdefault(key, 0); p["words"][key] += 1
print(json.dumps(per, sort_keys=True))
PY
)"
  echo "FIL-LOG $name $label $logsum"
  echo "${line#FIL-RUN }" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); r["app"]=sys.argv[1]; r["log"]=json.loads(sys.argv[2] or "{}"); print(json.dumps(r))' "$name" "$logsum" >>"$out/runs.jsonl"
  [[ "$line" != *'"error"'* ]]
}

# quiesce APP: wait (60 s at most) until nothing runs out of APP's Contents/MacOS or Contents/Frameworks, then 2 s.
quiesce() {
  local i
  for ((i = 0; i < 600; i++)); do
    [[ "$(ps -axo command= | LR_P="$1/Contents/" awk 'index($0, ENVIRON["LR_P"]) && !index($0, "/Resources/bin/") { n++ } END { print n + 0 }')" == 0 ]] && break
    sleep 0.1
  done
  sleep 2
}

ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }

# The approver the probe calls when it is not trusted for Accessibility itself: Cua Driver (on the fleet's display
# Macs, trusted) presses the dialog's Open button. approve.sh PID WINDOW_ID
write_approver() {
  cat >"$1" <<'SH'
#!/bin/bash
D=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
[ -x "$D" ] || { echo "no cua-driver"; exit 1; }
state="$("$D" call get_window_state "{\"pid\":$1,\"window_id\":$2,\"include_screenshot\":false}" 2>&1)"
idx="$(printf '%s' "$state" | python3 -I -c '
import json, re, sys
text = sys.stdin.read()
try:
    data = json.loads(text)
    els = (data.get("structuredContent") or data).get("elements") or []
    for e in els:
        if (e.get("role") or "").endswith("Button") and (e.get("label") or e.get("title") or "").strip() == "Open":
            print(e["element_index"]); break
except Exception:
    m = re.search(r"\[element_index (\d+)\][^\n]*Open", text)
    if m: print(m.group(1))
')"
[ -n "$idx" ] || { echo "no Open button: ${state:0:600}"; exit 1; }
"$D" call click "{\"pid\":$1,\"window_id\":$2,\"element_index\":$idx}" 2>&1 | head -c 300
echo; printf '%s' "$state" | grep -oE '"(value|label)": *"[^"]{20,}"' | head -3
SH
  chmod 0755 "$1"
}

summarize() {
  python3 -I - "$1" <<'PY'
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
def p95(v):
    v = sorted(v); return v[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))]
for app in dict.fromkeys(r["app"] for r in rows):
    done = [r for r in rows if r["app"] == app and r["label"] != "prime" and r.get("window") is not None]
    out = {"n": len(done)}
    for key in ("prompt", "prompt_dwell", "exec", "exec_system", "finished_launching", "window", "window_system", "settled", "settled_system", "pageins", "cpu_ms"):
        vals = [r[key] for r in done if isinstance(r.get(key), (int, float))]
        if vals:
            out[key] = {"median": round(statistics.median(vals), 1), "p95": round(p95(vals), 1), "min": min(vals), "max": max(vals)}
    marks = {}
    for r in done:
        for k, v in (r.get("marks") or {}).items():
            marks.setdefault(k, []).append(v)
    out["marks_median"] = {k: round(statistics.median(v), 1) for k, v in sorted(marks.items(), key=lambda kv: statistics.median(kv[1])) if len(v) == len(done)}
    procs = {}
    for r in done:
        for who, p in (r.get("log") or {}).items():
            procs.setdefault(who, []).append(p["last_ms"])
    out["log_last_ms_median"] = {k: statistics.median(v) for k, v in procs.items()}
    print("FIL-SUMMARY", app, json.dumps(out), flush=True)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit $?; fi
