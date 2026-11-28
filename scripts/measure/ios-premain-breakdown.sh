#!/usr/bin/env bash
# Where does cmux iOS spend the time before main()? The simctl arm (ios-first-connect-simctl.sh) shows the `main`
# mark at ~2.4 s after the kernel's start of the process, warm. This script writes three readings beside it:
#   1. the launch floor: a one-file SwiftUI app (scripts/measure/ios-launch-floor) through the same simctl arm,
#      so the simulator's own spawn and dyld cost is subtracted (premain-floor: simctl-first-connect-floor.json);
#   2. what the app loads: the main binary's size, its load commands (otool -L), and every embedded
#      framework/dylib with its size (premain-inventory.json);
#   3. one `xctrace record --template 'App Launch'` launch, exported to its tables (premain-trace/ and
#      premain-trace-summary.json): the pre-main phases (process creation, dyld, static initializers).
# Each reading is bounded and independent: one failing writes its error file and the rest still run.
#
#   bash scripts/measure/ios-premain-breakdown.sh --app PATH --measure-dir DIR [--out artifacts/ios-sim]
set -uo pipefail

out=artifacts/ios-sim
app=""
measure=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --measure-dir) measure="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "ios-premain-breakdown.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$app" ]]; then
  for c in .build/ios-sim/dd-ui/Build/Products/*-iphonesimulator/CmuxMobileApp.app \
           .build/ios-sim/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app; do
    [[ -d "$c" ]] && { app="$c"; break; }
  done
fi
[[ -n "$app" && -d "$app" ]] || { echo "ios-premain-breakdown.sh: no built CmuxMobileApp.app" >&2; exit 3; }
[[ -n "$measure" && -d "$measure" ]] || { echo "ios-premain-breakdown.sh: --measure-dir is required" >&2; exit 2; }
mkdir -p "$out"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/premain.XXXXXX")"
# macOS has no coreutils `timeout`: SECONDS CMD... runs CMD under an alarm (exit 142 when it fires).
bounded() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$s" "$@"; }

# 1. Floor.
echo "== premain: floor"
if floor_app="$(bash "$measure/ios-launch-floor/build.sh" "$work/floor" 2>"$out/premain-floor-build.err" | tail -1)" &&
   [[ -d "$floor_app" ]]; then
  bounded 600 bash "$measure/ios-first-connect-simctl.sh" --app "$floor_app" --runs 10 --out "$out" --tag floor \
    >"$out/premain-floor.log" 2>&1 || echo "floor arm failed: see premain-floor.log" >&2
else
  echo "floor build failed: see premain-floor-build.err" >&2
fi

# 2. Inventory.
echo "== premain: inventory"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
otool -L "$app/$exe" >"$work/otool.txt" 2>&1 || true
otool -l "$app/$exe" >"$work/otool-l.txt" 2>&1 || true
python3 -I - "$app" "$exe" "$work/otool.txt" "$work/otool-l.txt" "$out/premain-inventory.json" <<'PY'
import json, os, pathlib, re, sys
app, exe, otool, otool_l, dest = sys.argv[1:]
root = pathlib.Path(app)
def size(p):
    p = pathlib.Path(p)
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
embedded = []
for f in sorted(root.rglob("*")):
    if f.suffix in (".framework", ".dylib") and (f.suffix == ".dylib" or f.is_dir()):
        embedded.append({"path": str(f.relative_to(root)), "bytes": size(f)})
loads = [l.split(" (")[0].strip() for l in open(otool).read().splitlines()[1:] if l.strip()]
lc = open(otool_l).read()
sections = {}
for m in re.finditer(r"sectname (\S+)\n\s+segname (\S+)\n(?:.*\n){0,2}?\s+size (0x[0-9a-f]+)", lc):
    sections[f"{m.group(2)},{m.group(1)}"] = int(m.group(3), 16)
out = {"app": app, "executable": exe, "executable_bytes": size(root / exe), "bundle_bytes": size(root),
       "embedded_count": len(embedded), "embedded_bytes": sum(e["bytes"] for e in embedded),
       "embedded": sorted(embedded, key=lambda e: -e["bytes"]),
       "loads_count": len(loads), "loads": loads,
       "sections_bytes_top": dict(sorted(sections.items(), key=lambda kv: -kv[1])[:30]),
       "init_sections_bytes": {k: v for k, v in sections.items()
                               if any(s in k for s in ("mod_init_func", "init_offsets", "objc_nlclslist",
                                                       "objc_nlcatlist", "swift5_protos", "swift5_types",
                                                       "swift5_proto", "objc_classlist", "chain_starts"))}}
pathlib.Path(dest).write_text(json.dumps(out, indent=1) + "\n")
print(f"inventory: executable {out['executable_bytes']} B, {out['embedded_count']} embedded "
      f"({out['embedded_bytes']} B), {out['loads_count']} load commands")
PY

# 3. One App Launch trace, in the default device set (xctrace does not take --set).
echo "== premain: xctrace App Launch"
trace="$work/launch.trace"
read -r runtime device_type _ <<<"$(xcrun simctl list -j runtimes devicetypes |
  python3 -I scripts/ci/ios_sim_runtime.py --with-name)"
udid="$(xcrun simctl create premain-trace "$device_type" "$runtime")"
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1; xcrun simctl delete "$udid" >/dev/null 2>&1' EXIT
xcrun simctl boot "$udid" && xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
# Two warm launches first, as the simctl arm's run 0.
for _ in 1 2; do
  SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" "$bundle" -cmuxMobile.setupComplete YES >/dev/null 2>&1
  sleep 4
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1
  sleep 1
done
mkdir -p "$out/premain-trace"
if bounded 240 xcrun xctrace record --template 'App Launch' --device "$udid" --time-limit 15s \
     --output "$trace" --env CMUX_MOBILE_MOCK_AUTH=1 --launch -- "$app" -cmuxMobile.setupComplete YES \
     >"$out/premain-trace/record.log" 2>&1 && [[ -d "$trace" ]]; then
  xcrun xctrace export --input "$trace" --toc >"$out/premain-trace/toc.xml" 2>"$out/premain-trace/toc.err" || true
  python3 -I - "$out/premain-trace/toc.xml" <<'PY' >"$work/schemas.txt"
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception:
    sys.exit(0)
for t in root.iter("table"):
    s = t.get("schema")
    if s:
        print(s)
PY
  sort -u "$work/schemas.txt" | while read -r schema; do
    case "$schema" in
      *life*|*dyld*|*static*|*init*|*launch*|*process*|*thread-state*|*time-profile*|*region*|*os-signpost*)
        bounded 120 xcrun xctrace export --input "$trace" \
          --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
          >"$out/premain-trace/$schema.xml" 2>/dev/null || true ;;
    esac
  done
  (cd "$work" && zip -qry "$OLDPWD/$out/premain-trace/launch.trace.zip" launch.trace) || true
  python3 -I - "$out/premain-trace" "$out/premain-trace-summary.json" <<'PY'
# Best-effort: each exported table's rows with a start, duration and a name-like column, longest first.
import json, pathlib, sys, xml.etree.ElementTree as ET
d, dest = pathlib.Path(sys.argv[1]), sys.argv[2]
summary = {}
for f in sorted(d.glob("*.xml")):
    if f.name == "toc.xml":
        continue
    try:
        root = ET.parse(f).getroot()
    except Exception as e:
        summary[f.stem] = {"error": str(e)[:200]}
        continue
    ids = {}
    for el in root.iter():
        if el.get("id"):
            ids[el.get("id")] = el
    def val(el):
        if el is None:
            return None
        if el.get("ref"):
            el = ids.get(el.get("ref"), el)
        return el.get("fmt") or (el.text or "").strip()
    rows = []
    for row in root.iter("row"):
        cells = list(row)
        dur = None
        name = []
        for c in cells:
            target = ids.get(c.get("ref"), c) if c.get("ref") else c
            tag = target.tag
            if tag in ("duration",) and target.text and target.text.strip().isdigit():
                dur = int(target.text.strip()) / 1e6
            elif tag in ("string", "process", "thread", "event-concept", "narrative", "os-signpost-name",
                         "app-period", "life-cycle-period", "subsystem", "category", "formatted-label"):
                v = val(c)
                if v:
                    name.append(v[:120])
        if dur is not None:
            rows.append({"ms": round(dur, 2), "what": " | ".join(name)[:300]})
    rows.sort(key=lambda r: -r["ms"])
    summary[f.stem] = {"rows": len(rows), "top": rows[:25]}
pathlib.Path(dest).write_text(json.dumps(summary, indent=1) + "\n")
for k, v in summary.items():
    for r in v.get("top", [])[:8]:
        print(f"trace {k}: {r['ms']} ms  {r['what']}")
PY
else
  echo "xctrace record failed: see premain-trace/record.log" >&2
  tail -20 "$out/premain-trace/record.log" >&2 || true
fi

python3 -I - "$out" <<'PY'
import json, pathlib, sys
o = pathlib.Path(sys.argv[1])
line = {}
for name, key in (("simctl-first-connect.json", "app"), ("simctl-first-connect-floor.json", "floor")):
    p = o / name
    if p.exists():
        d = json.loads(p.read_text())
        line[key] = {m: d["marks"][m]["p90_ms"] for m in ("main", "did_finish_launching", "workspaces_list_frame")
                     if m in d["marks"]}
        line[key]["spawn_lead_p90"] = d.get("spawn", {}).get("process_start_minus_simctl_call_ms", {}).get("p90")
inv = o / "premain-inventory.json"
if inv.exists():
    d = json.loads(inv.read_text())
    line["inventory"] = {"executable_bytes": d["executable_bytes"], "embedded_count": d["embedded_count"],
                         "embedded_bytes": d["embedded_bytes"], "loads_count": d["loads_count"]}
print("PREMAIN " + json.dumps(line))
PY
