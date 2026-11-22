#!/usr/bin/env bash
# What a new copy's first exec pays before `main`, and what that cost scales with (CMUX-629, the cold launch: about
# 4.5 s of 5.2 s on one laptop is the system's check before main). One DMG, on a fleet Mac's console session:
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/firstexec-study.sh --ref <sha> [--arg=dmg=nightly|URL|sha256:HEX] [--arg=reps=5] \
#     [--arg=arms=devid,nostaple,adhoc,lean,pad,nores,load,helper] [--arg=trace=1] \
#     --artifact .build/firstexec-study/report.tgz --timeout 5400
# Each arm is a variant of the DMG's app, made once ("master"); every rep makes a new copy of the master (ditto, a new
# path and new files, as an update in place or a drag makes them) and measures the copy's first exec of its main
# executable, started suspended and stopped at the app's `main_start` mark (launch-premain.swift exec with HOLD):
# spawn_ms (the kernel's exec), resume_to_main (dyld, the linked frameworks, initializers), main_start (ms from
# process start), and the CPU syspolicyd, XprotectService, amfid and trustd spent across it. Then the same copy's
# second exec (role second) as the control: a cost a second exec does not pay is the once-per-copy check.
#   devid     the app as shipped (Developer ID, notarized, its ticket stapled)
#   nostaple  devid without the stapled ticket (Contents/CodeResources, outside the signature's seal)
#   adhoc     every code object re-signed ad hoc (codesign --force --deep -s -): the baseline for the next three
#   lean      adhoc after removing every nested code object the executable does not link: the helper apps, the
#             Mach-O files under Contents/Resources (bundled CLIs, .node addons, daemons) and loose dylibs nothing
#             loads at launch. Fewer code objects and fewer bytes
#   pad       lean, each removed Mach-O file replaced by a file of the same size that is not code: fewer code objects,
#             the same bytes
#   nores     adhoc after removing every file over 256 KB that is not Mach-O: the same code objects, fewer bytes
#   load      devid, measured while one busy loop per CPU runs: how the wait scales with a loaded Mac
#   helper    devid, the smallest helper app's executable spawned first (suspended, killed): whether a nested bundle's
#             first exec pays the whole app's check; then the main executable's first exec as above
# trace=1 records rep 1 of devid and adhoc with fs_usage (root) and the checkers' system log: which files of the copy
# each checker read, and how many bytes. Prints FX-INV (the masters' inventory), FX-RUN per exec, FX-TABLE per arm.
set -uo pipefail

FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# console, fetch_dmg, copy_app, gate, checker_cpu, load1, wait_load, fresh_keychain: the pre-main study's helpers.
source "$FX_DIR/launch-premain.sh"

ALL_ARMS="devid,nostaple,adhoc,lean,pad,nores,load,helper"
NORESULT='LP-RUN {"error": "no result"}'

main() {
  cd "$FX_DIR/../.." || exit 3
  local out="$PWD/.build/firstexec-study" dmg=nightly reps=5 arms="$ALL_ARMS" trace=0 arg rc=0 rep arm
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=https://*|dmg=sha256:*) dmg="${arg#dmg=}" ;;
      reps=*) reps="${arg#reps=}" ;;
      arms=*) arms="${arg#arms=}" ;;
      trace=0|trace=1) trace="${arg#trace=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$reps" =~ ^([1-9]|1[0-2])$ ]] || { echo "reps= must be 1 to 12" >&2; exit 2; }
  [[ "$arms" =~ ^(devid|nostaple|adhoc|lean|pad|nores|load|helper)(,(devid|nostaple|adhoc|lean|pad|nores|load|helper))*$ ]] \
    || { echo "arms= takes $ALL_ARMS" >&2; exit 2; }
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  OUT="$out"
  echo "FX host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" cpus=$(sysctl -n hw.ncpu) perf=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null) macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) session $(launchctl managername)"
  sudo -n -l /usr/bin/fs_usage >/dev/null 2>&1 && echo "FX root fs_usage yes" || echo "FX root fs_usage no (trace=1 records only the log)"
  xcrun swiftc -O -o "$out/launch-premain" scripts/measure/launch-premain.swift >"$out/swiftc.log" 2>&1 \
    || { echo "FX probe build failed"; cat "$out/swiftc.log"; exit 3; }
  fetch_dmg "$dmg" "$out/app.dmg" || exit $?
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  mkdir -p "$out/mnt" "$out/masters"
  local shipped; shipped="$(copy_app "$out/app.dmg" "$out/mnt" "$out/masters")" || exit 3
  NAME="$(basename "$shipped")"
  gate app exec "$shipped"
  local list; IFS=, read -r -a list <<<"$arms"
  local needed=() a
  for a in "${list[@]}"; do
    case "$a" in
      devid|load|helper) needed+=(devid) ;;
      nostaple) needed+=(nostaple) ;;
      adhoc) needed+=(adhoc) ;;
      lean) needed+=(adhoc lean) ;;
      pad) needed+=(adhoc pad) ;;
      nores) needed+=(adhoc nores) ;;
    esac
  done
  for a in devid nostaple adhoc lean pad nores; do
    [[ " ${needed[*]} " == *" $a "* ]] && { make_master "$a" "$shipped" || { echo "FX-FAIL master $a"; rc=1; }; }
  done
  for a in devid nostaple adhoc lean pad nores; do
    [[ -d "$out/masters/$a/$NAME" ]] && inventory "$a" "$out/masters/$a/$NAME"
  done
  if [[ "$trace" == 1 ]]; then
    for arm in devid adhoc; do
      [[ ",$arms," == *",$arm,"* && -d "$out/masters/$arm/$NAME" ]] || continue
      wait_load "$arm" T; run_arm "$arm" T || rc=1
    done
  fi
  for ((rep = 1; rep <= reps; rep++)); do
    local n=${#list[@]} k
    for ((k = 0; k < n; k++)); do
      arm="${list[$(((k + rep - 1) % n))]}"
      wait_load "$arm" "$rep"
      run_arm "$arm" "$rep" || rc=1
    done
  done
  table "$out/runs.jsonl"
  local pids; pids="$(ps -axo pid=,command= | FX_ROOT="$out/" awk 'index($0, ENVIRON["FX_ROOT"]) { print $1 }')"
  [[ -n "$pids" ]] && { sudo -n kill $pids 2>/dev/null || kill $pids 2>/dev/null; }
  tar -czf "$out.tgz" -C "$out" --exclude '*.dmg' --exclude masters --exclude 'copy-*' --exclude 'home-*' --exclude mnt . 2>/dev/null \
    && mv "$out.tgz" "$out/report.tgz"
  rm -rf "$out/masters" "$out"/copy-* "$out"/home-*
  exit "$rc"
}

# is_macho FILE: true for a Mach-O or universal file (its magic).
is_macho() {
  local magic; magic="$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ "$magic" == cffaedfe || "$magic" == cafebabe || "$magic" == cefaedfe || "$magic" == bebafeca ]]
}

# removable APP: the nested code the executable does not load before `main`, one path per line: helper apps under
# Contents/Frameworks, Mach-O files under Contents/Resources, and dylibs in Contents/Frameworks that neither the
# executable nor a framework it links names in a load command.
removable() {
  local app="$1" exe linked f
  exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  # Names linked by the executable, by every top-level framework, and by every top-level dylib (so a dylib that only
  # another dylib loads is kept too: conservative, it may keep a dylib nothing loads).
  linked="$( { otool -L "$exe"; find "$app/Contents/Frameworks" -maxdepth 1 -name '*.framework' | while read -r f; do
    local b; b="$(basename "$f" .framework)"; [[ -f "$f/$b" ]] && otool -L "$f/$b"; done
    # A dylib's first entry is its own install name: skipped, or every dylib would count as linked.
    find "$app/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' | while read -r f; do otool -L "$f" | tail -n +3; done; } 2>/dev/null \
    | awk '/^[[:space:]]/ { print $1 }' | sed 's#.*/##' | sort -u)"
  find "$app/Contents/Frameworks" -maxdepth 1 -name '*.app' -print
  find "$app/Contents/Resources" -type f 2>/dev/null | while read -r f; do is_macho "$f" && echo "$f"; done
  find "$app/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' | while read -r f; do
    grep -qxF "$(basename "$f")" <<<"$linked" || echo "$f"
  done
}

# src_of SHIPPED: the devid master when it was made, else the shipped copy (a run whose arms leave devid out).
src_of() { if [[ -d "$OUT/masters/devid/$NAME" ]]; then echo "$OUT/masters/devid/$NAME"; else echo "$1"; fi; }

# make_master ARM SHIPPED: the arm's variant at $OUT/masters/ARM/NAME, with an FX-MASTER line (time to make, verify).
make_master() {
  local arm="$1" shipped="$2" dir="$OUT/masters/$1" app t0 removed=0 bytes=0 f size
  mkdir -p "$dir"; app="$dir/$NAME"
  t0="$(date +%s)"
  case "$arm" in
    devid) mv "$shipped" "$app" ;;
    nostaple) ditto "$(src_of "$shipped")" "$app" || return 1
      [[ -f "$app/Contents/CodeResources" ]] && { rm -f "$app/Contents/CodeResources"; removed=1; } ;;
    adhoc) ditto "$(src_of "$shipped")" "$app" || return 1
      codesign --force --deep --preserve-metadata=entitlements,flags,runtime --sign - "$app" >"$OUT/sign-$arm.log" 2>&1 || { tail -5 "$OUT/sign-$arm.log"; return 1; } ;;
    lean|pad|nores) ditto "$(src_of "$shipped")" "$app" || return 1
      if [[ "$arm" == nores ]]; then
        while read -r f; do
          is_macho "$f" && continue
          size="$(stat -f %z "$f")"; rm -f "$f"; removed=$((removed + 1)); bytes=$((bytes + size))
        done < <(find "$app/Contents" -type f -size +512 ! -name CodeResources ! -name Info.plist ! -path '*/_CodeSignature/*')
      else
        while read -r f; do
          [[ -e "$f" ]] || continue
          if [[ -d "$f" ]]; then
            size="$(find "$f" -type f -exec stat -f %z {} + | awk '{ s += $1 } END { print s + 0 }')"
          else
            size="$(stat -f %z "$f")"
          fi
          rm -rf "$f"
          # pad: the removed bytes come back as one data file each under Contents/Resources/fx-pad (a data file in
          # Contents/Frameworks would be taken for unsigned nested code).
          if [[ "$arm" == pad ]]; then
            mkdir -p "$app/Contents/Resources/fx-pad"
            head -c "$size" /dev/urandom >"$app/Contents/Resources/fx-pad/$removed-$(basename "$f").pad"
          fi
          removed=$((removed + 1)); bytes=$((bytes + size))
        done < <(removable "$app")
      fi
      codesign --force --deep --preserve-metadata=entitlements,flags,runtime --sign - "$app" >"$OUT/sign-$arm.log" 2>&1 || { tail -5 "$OUT/sign-$arm.log"; return 1; } ;;
  esac
  local verify; verify="$(codesign --verify --deep --strict "$app" 2>&1 | tail -1)"; [[ -z "$verify" ]] && verify=ok
  echo "FX-MASTER $arm made_s=$(($(date +%s) - t0)) removed=$removed removed_bytes=$bytes verify=\"$verify\" $(codesign -dv "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier|flags|CodeDirectory)' | head -3 | tr '\n' ' ')"
}

# inventory ARM APP: the files, bytes, Mach-O files and bytes, nested bundles and signatures (_CodeSignature dirs).
inventory() {
  python3 -I - "$1" "$2" <<'PY'
import json, os, sys
arm, app = sys.argv[1], sys.argv[2]
magic = {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe", b"\xbe\xba\xfe\xca"}
files = total = macho = macho_bytes = sigs = 0
bundles = {}
biggest = []
for root, dirs, names in os.walk(app):
    for d in dirs:
        for ext in (".app", ".framework", ".bundle", ".xpc", ".appex", ".plugin"):
            if d.endswith(ext): bundles[ext] = bundles.get(ext, 0) + 1
        if d == "_CodeSignature": sigs += 1
    for n in names:
        p = os.path.join(root, n)
        if os.path.islink(p): continue
        s = os.path.getsize(p); files += 1; total += s
        with open(p, "rb") as h:
            if h.read(4) in magic:
                macho += 1; macho_bytes += s; biggest.append((s, os.path.relpath(p, app)))
biggest.sort(reverse=True)
print("FX-INV", json.dumps({"arm": arm, "files": files, "bytes": total, "macho_files": macho, "macho_bytes": macho_bytes,
      "signatures": sigs, "bundles": bundles, "stapled": os.path.exists(os.path.join(app, "Contents/CodeResources")),
      "largest_macho": [[round(s / 1e6, 1), p] for s, p in biggest[:12]]}), flush=True)
PY
}

# busy N: N busy loops in the background; prints their pids.
busy() { local i; for ((i = 0; i < $1; i++)); do ( while :; do :; done ) >/dev/null 2>&1 & echo $!; done; }

# run_arm ARM REP: a new copy of ARM's master, its first exec measured, then its second; the copy deleted.
run_arm() {
  local arm="$1" rep="$2" tag="$1-$2" master app line cpu_before cpu_after rc=0 hogs="" trace_pid="" t0 helper_line=""
  case "$arm" in load|helper) master="$OUT/masters/devid/$NAME" ;; *) master="$OUT/masters/$arm/$NAME" ;; esac
  [[ -d "$master" ]] || { echo "FX-RUN {\"arm\": \"$arm\", \"rep\": \"$rep\", \"error\": \"no master\"}"; return 1; }
  mkdir -p "$OUT/copy-$tag" "$OUT/home-$tag" && chmod 0777 "$OUT/home-$tag"
  app="$OUT/copy-$tag/$NAME"
  ditto "$master" "$app" || return 1
  sync; sleep 2
  fresh_keychain "$OUT/home-$tag/h" || true
  if [[ "$rep" == T ]]; then
    if sudo -n -l /usr/bin/fs_usage >/dev/null 2>&1; then
      # shellcheck disable=SC2024
      sudo -n /usr/bin/fs_usage -w -t 40 -f filesys >"$OUT/fs-$tag.txt" 2>&1 &
      trace_pid=$!; sleep 1
    fi
    t0="$(date '+%Y-%m-%d %H:%M:%S')"
  fi
  cpu_before="$(checker_cpu)"
  [[ "$arm" == load ]] && hogs="$(busy "$(sysctl -n hw.ncpu)")" && sleep 1
  if [[ "$arm" == helper ]]; then
    local h
    h="$(find "$app/Contents/Frameworks" -maxdepth 1 -name '* Helper*.app' | while read -r d; do
      e="$d/Contents/MacOS/$(basename "$d" .app)"; [[ -x "$e" ]] && echo "$(stat -f %z "$e") $e"; done | sort -n | head -1 | cut -d' ' -f2-)"
    helper_line="$(console "$OUT/launch-premain" spawn "$h" "$tag" 2>>"$OUT/probe.log" | grep '^LP-RUN ')"
    record_fx "$arm" "$rep" helper "${helper_line:-$NORESULT}" "$cpu_before" "$(checker_cpu)"
    cpu_before="$(checker_cpu)"
  fi
  touch "$OUT/hold-$tag" && chmod 0666 "$OUT/hold-$tag"
  line="$(console "$OUT/launch-premain" exec "$app" "$OUT/home-$tag" "$tag" "$OUT/hold-$tag" 2>>"$OUT/probe.log" | grep '^LP-RUN ')" || rc=1
  [[ -n "$hogs" ]] && kill $hogs 2>/dev/null
  cpu_after="$(checker_cpu)"
  record_fx "$arm" "$rep" first "${line:-$NORESULT}" "$cpu_before" "$cpu_after"
  if [[ -n "$trace_pid" ]]; then kill -INT "$trace_pid" 2>/dev/null; wait "$trace_pid" 2>/dev/null; fs_reduce "$tag" "$app"; fi
  [[ "$rep" == T ]] && log show --start "$t0" --style compact \
    --predicate 'process == "syspolicyd" OR process == "XprotectService" OR process == "amfid" OR sender == "AppleSystemPolicy" OR sender == "AppleMobileFileIntegrity"' \
    >"$OUT/log-$tag.txt" 2>&1
  sleep 2
  cpu_before="$(checker_cpu)"
  line="$(console "$OUT/launch-premain" exec "$app" "$OUT/home-$tag" "$tag" "$OUT/hold-$tag" 2>>"$OUT/probe.log" | grep '^LP-RUN ')" || rc=1
  record_fx "$arm" "$rep" second "${line:-$NORESULT}" "$cpu_before" "$(checker_cpu)"
  rm -f "$OUT/hold-$tag"
  local pids; pids="$(ps -axo pid=,command= | FX_COPY="$OUT/copy-$tag/" awk 'index($0, ENVIRON["FX_COPY"]) { print $1 }')"
  [[ -n "$pids" ]] && { sudo -n kill $pids 2>/dev/null || kill $pids 2>/dev/null; sleep 1; }
  rm -rf "$OUT/copy-$tag" "$OUT/home-$tag"
  return $rc
}

# record_fx ARM REP ROLE LINE BEFORE AFTER: LINE's JSON with the checkers' CPU deltas, to stdout and runs.jsonl.
record_fx() {
  local json
  json="$(echo "${4#LP-RUN }" | python3 -I -c '
import json, sys
try: r = json.load(sys.stdin)
except Exception: r = {"error": "unreadable probe line"}
b = dict(p.split("=") for p in sys.argv[4].split()); a = dict(p.split("=") for p in sys.argv[5].split())
for k in b: r[k + "_ms"] = (int(a[k]) - int(b[k])) if int(a[k]) >= int(b[k]) else None  # a checker that exited between readings
r.update(arm=sys.argv[1], rep=sys.argv[2] if sys.argv[2] == "T" else int(sys.argv[2]), role=sys.argv[3], load=float(sys.argv[6]))
print(json.dumps(r, sort_keys=True))' "$1" "$2" "$3" "$5" "$6" "$(load1)")"
  echo "FX-RUN $json"
  echo "$json" >>"$OUT/runs.jsonl"
}

# fs_reduce TAG APP: from fs-TAG.txt, per checker process, the files of the copy it touched and bytes it read
# (fs_usage's B=0x... on reads): FX-TRACE.
fs_reduce() {
  python3 -I - "$OUT/fs-$1.txt" "$2" "$1" <<'PY'
import json, re, sys
path, app, tag = sys.argv[1], sys.argv[2], sys.argv[3]
procs = {}
for line in open(path, errors="replace"):
    parts = line.rstrip().rsplit(None, 1)
    if len(parts) < 2: continue
    proc = re.sub(r"\.\d+$", "", parts[1])
    if not any(k in proc for k in ("syspolicyd", "XprotectService", "amfid", "trustd", "launch-premain", "cmux", "NEXT", "Helper")): continue
    d = procs.setdefault(proc, {"calls": 0, "files": set(), "read_bytes": 0})
    d["calls"] += 1
    if app in line: d["files"].add(re.split(r"\s{2,}", line[line.index(app) + len(app):])[0])
    m = re.search(r"B=0x([0-9a-f]+)", line)
    if m and re.search(r"\b(read|pread|RdData)", line): d["read_bytes"] += int(m.group(1), 16)
out = {p: {"calls": d["calls"], "files": len(d["files"]), "read_bytes": d["read_bytes"], "sample": sorted(d["files"])[:8]} for p, d in procs.items()}
print("FX-TRACE", json.dumps({"tag": tag, "procs": out}), flush=True)
PY
}

table() {
  python3 -I - "$1" <<'PY'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
def med(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    return {"median": round(statistics.median(vals), 1), "min": min(vals), "max": max(vals), "n": len(vals)} if vals else None
for arm in dict.fromkeys(r["arm"] for r in rows):
    for role in ("helper", "first", "second"):
        runs = [r for r in rows if r["arm"] == arm and r["role"] == role and r.get("rep") != "T"]
        if not runs: continue
        t = {"arm": arm, "role": role, "errors": sum(1 for r in runs if r.get("error"))}
        for key in ("main_start", "spawn_ms", "resume_to_main", "request_to_start", "user_ms", "system_ms", "pageins",
                    "syspolicyd_ms", "xprotect_ms", "amfid_ms", "trustd_ms", "load"):
            t[key] = med([r.get(key) for r in runs])
        print("FX-TABLE", json.dumps(t), flush=True)
PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit $?; fi
