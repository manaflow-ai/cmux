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
# 1b. Floor variants through the same simctl arm; each one's main minus the floor's is what it adds:
#   floor-webrtc  cmux's WebRTC.framework loaded at launch
#   floor-pad     the floor padded to the app's __TEXT,__text size in a section never touched (size alone)
#   floor-rust    the floor with cmux's whole Rust FFI static library force-loaded (its code, data, fixups)
floor_arm() { # TAG BUILD-ARGS...
  local tag="$1"; shift
  local a
  echo "== premain: $tag"
  if a="$(bash "$measure/ios-launch-floor/build.sh" "$work/$tag" "$@" 2>"$out/premain-$tag-build.err" | tail -1)" &&
     [[ -d "$a" ]]; then
    bounded 600 bash "$measure/ios-first-connect-simctl.sh" --app "$a" --runs 10 --out "$out" --tag "$tag" \
      >"$out/premain-$tag.log" 2>&1 || echo "$tag arm failed: see premain-$tag.log" >&2
  else
    echo "$tag build failed: see premain-$tag-build.err" >&2
  fi
}
[[ -d "$app/Frameworks/WebRTC.framework" ]] && floor_arm floor-webrtc --webrtc "$app/Frameworks/WebRTC.framework"
exe0="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
text_bytes="$(otool -l "$app/$exe0" 2>/dev/null | python3 -I -c 'import re,sys
m=re.search(r"sectname __text\n\s+segname __TEXT\n\s+addr 0x[0-9a-f]+\n\s+size (0x[0-9a-f]+)",sys.stdin.read())
print(int(m.group(1),16) if m else 0)')"
echo "app __TEXT,__text bytes: $text_bytes"
[[ "$text_bytes" =~ ^[0-9]+$ && "$text_bytes" -gt 0 ]] && floor_arm floor-pad --pad "$text_bytes"
ffi_lib="$(find "$PWD" -path '*CmuxMobileLinkFFI*simulator*' -name 'CmuxMobileLinkFFIFFI' -type f -size +1M \
  2>/dev/null | head -1)"
[[ -n "$ffi_lib" ]] || ffi_lib="$(find "$PWD" -path '*simulator*' -name 'libcmux_mobile_link_ffi.a' -type f 2>/dev/null | head -1)"
echo "rust static library: ${ffi_lib:-not found}" | tee "$out/premain-rust-lib.txt"
if [[ -n "$ffi_lib" ]]; then
  { ls -l "$ffi_lib"; lipo -info "$ffi_lib"; } >>"$out/premain-rust-lib.txt" 2>&1
  floor_arm floor-rust --force-load "$ffi_lib"
fi
# The app's entitlements: Xcode puts a simulator build's in __TEXT,__entitlements (the code signature may hold none).
python3 -I - "$app/$exe0" "$work/app-ent.plist" <<'PY' || true
import re, subprocess, sys
exe, dest = sys.argv[1:]
lc = subprocess.run(["otool", "-l", exe], capture_output=True, text=True).stdout
m = re.search(r"sectname __entitlements\n\s+segname __TEXT\n\s+addr 0x[0-9a-f]+\n\s+size (0x[0-9a-f]+)\n\s+offset (\d+)", lc)
data = b""
if m:
    with open(exe, "rb") as f:
        f.seek(int(m.group(2)))
        data = f.read(int(m.group(1), 16))
if b"<plist" not in data:
    data = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", exe], capture_output=True).stdout
if b"<plist" in data:
    open(dest, "wb").write(data[data.index(b"<?xml") if b"<?xml" in data else data.index(b"<plist"):].rstrip(b"\0"))
PY
if [[ -s "$work/app-ent.plist" ]]; then
  cp "$work/app-ent.plist" "$out/premain-app-entitlements.plist"
  floor_arm floor-ent --ent "$work/app-ent.plist"
else
  echo "app entitlements: none found" | tee "$out/premain-app-entitlements.plist"
fi
# The app's own load commands (system frameworks, /usr/lib and Swift dylibs), loaded by the floor.
otool -L "$app/$exe0" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//' >"$work/app-loads.txt"
floor_arm floor-dylibs --needed-from "$work/app-loads.txt"
cp "$work/floor-dylibs/needed-used.txt" "$out/premain-floor-dylibs-used.txt" 2>/dev/null || true
cp "$work/floor-dylibs/needed-skipped.txt" "$out/premain-floor-dylibs-skipped.txt" 2>/dev/null || true
# The app's bundle (Info.plist, embedded frameworks, extensions, resources, assets, signature) with the floor's
# executable in place of its own, signed with the app's entitlements: near the app's main, the cost is the
# bundle's or the spawn's; near the floor's, it is the executable's.
echo "== premain: app-shell"
shell_exe="$(ls "$work"/floor-ent/*.app/CmuxLaunchFloorEnt "$work"/floor/*.app/CmuxLaunchFloor 2>/dev/null | head -1)"
if [[ -n "$shell_exe" ]]; then
  mkdir -p "$work/app-shell"
  cp -R "$app" "$work/app-shell/"
  shell_app="$work/app-shell/$(basename "$app")"
  cp "$shell_exe" "$shell_app/$exe0"
  if [[ -s "$work/app-ent.plist" ]]; then
    codesign --force --sign - --entitlements "$work/app-ent.plist" "$shell_app" >"$out/premain-app-shell-build.err" 2>&1
  else
    codesign --force --sign - "$shell_app" >"$out/premain-app-shell-build.err" 2>&1
  fi
  bounded 600 bash "$measure/ios-first-connect-simctl.sh" --app "$shell_app" --runs 10 --out "$out" --tag app-shell \
    >"$out/premain-app-shell.log" 2>&1 || echo "app-shell arm failed: see premain-app-shell.log" >&2
fi

# 2. Inventory.
echo "== premain: inventory"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
otool -L "$app/$exe" >"$work/otool.txt" 2>&1 || true
otool -l "$app/$exe" >"$work/otool-l.txt" 2>&1 || true
nm -n -m "$app/$exe" >"$work/nm.txt" 2>/dev/null || true
size -m "$app/$exe" >"$out/premain-size-m.txt" 2>&1 || true
python3 -I - "$app" "$exe" "$work/otool.txt" "$work/otool-l.txt" "$out/premain-inventory.json" "$work/nm.txt" <<'PY'
import json, os, pathlib, re, sys
app, exe, otool, otool_l, dest, nm = sys.argv[1:]
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
# __TEXT,__text by language: each symbol owns the bytes up to the next symbol's address.
rust_legacy = re.compile(r"17h[0-9a-f]{16}E$")
def lang(n):
    if n.startswith(("_$s", "_$S", "_swift_", "__swift", "_$ss")):
        return "swift"
    if n.startswith(("__R", "_uniffi_", "_ffi_")) or (n.startswith("__ZN") and rust_legacy.search(n)):
        return "rust"
    if n.startswith("__Z"):
        return "c++"
    if n.startswith(("-[", "+[")):
        return "objc"
    return "c/zig/other"
syms = []
try:
    for l in open(nm, errors="replace"):
        m = re.match(r"([0-9a-f]+) \(__TEXT,__text\) .*? (\S+)$", l.rstrip())
        if m:
            syms.append((int(m.group(1), 16), m.group(2)))
except OSError:
    pass
tm = re.search(r"sectname __text\n\s+segname __TEXT\n\s+addr (0x[0-9a-f]+)\n\s+size (0x[0-9a-f]+)", lc)
end = int(tm.group(1), 16) + int(tm.group(2), 16) if tm else None
by = {}
for i, (a, n) in enumerate(syms):
    nxt = syms[i + 1][0] if i + 1 < len(syms) else (end or a)
    by[lang(n)] = by.get(lang(n), 0) + max(0, nxt - a)
out["text_bytes_by_lang"] = dict(sorted(by.items(), key=lambda kv: -kv[1]))
out["text_symbols"] = len(syms)
pathlib.Path(dest).write_text(json.dumps(out, indent=1) + "\n")
print("text by language:", out["text_bytes_by_lang"])
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
# 3a. A host `sample` of one warm launch, attached as soon as simctl returns the pid (main lands ~2 s later, so
# dyld, the initializers and main are all in it). Samples are 1 ms apart: counts read as ms of the main thread.
echo "== premain: sample"
if line="$(SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$udid" "$bundle" -cmuxMobile.setupComplete YES 2>&1)"; then
  spid="${line##*: }"
  bounded 30 sample "$spid" 4 1 -mayDie -file "$out/premain-sample.txt" >"$work/sample.log" 2>&1 || true
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  sleep 1
  python3 -I - "$out/premain-sample.txt" "$out/premain-sample-summary.json" <<'PY' || true
import json, re, sys
src, dest = sys.argv[1:]
try:
    text = open(src, errors="replace").read()
except OSError:
    sys.exit(0)
graph = text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
inclusive, main_thread = {}, None
for l in graph.splitlines():
    m = re.match(r"^[\s+!:|]*(\d+)\s+(.+?)(?:\s+\(in ([^)]+)\))?(?:\s+\+\s.*|\s+\[.*)?$", l)
    if not m:
        continue
    count, name, image = int(m.group(1)), m.group(2).strip(), m.group(3) or ""
    if name.startswith("Thread_"):
        if main_thread is not None:
            break  # the first thread is the main thread
        main_thread = count
        continue
    key = f"{name} ({image})" if image else name
    inclusive[key] = max(inclusive.get(key, 0), count)
pre = {k: v for k, v in inclusive.items() if re.search(
    r"dyld4::|dyld3::|runAllInitializers|Fixup|fixup|bind|Bind|mapSegments|mmap|_dyld_start|swift_conform|"
    r"objc_init|map_images|load_images|initializeMainExecutable|libSystem_initializer|vm_fault|page", k)}
summary = {"main_thread_samples": main_thread,
           "main_in_samples": max((v for k, v in inclusive.items() if re.match(r"main \(", k)), default=None),
           "premain_frames": dict(sorted(pre.items(), key=lambda kv: -kv[1])[:30]),
           "inclusive_top": dict(sorted(inclusive.items(), key=lambda kv: -kv[1])[:50])}
open(dest, "w").write(json.dumps(summary, indent=1) + "\n")
print("sample: main thread %s, main %s; pre-main frames %s" % (
    main_thread, summary["main_in_samples"], list(summary["premain_frames"].items())[:8]))
PY
else
  echo "sample launch failed: $line" >&2
fi

# 3b. One warm launch with dyld's library log, each line stamped with ms since the `simctl launch` call, beside
# the launch's own marks: when dyld starts printing, when it stops, and when `main` runs.
echo "== premain: dyld log"
SIMCTL_CHILD_DYLD_PRINT_LIBRARIES=1 SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 \
  bounded 20 xcrun simctl launch --console-pty "$udid" "$bundle" -cmuxMobile.setupComplete YES 2>&1 |
  perl -MTime::HiRes=time -ne 'BEGIN { $t0 = time; $| = 1 } printf "%8.1f %s", (time - $t0) * 1000, $_' \
  >"$out/premain-dyld-libraries.txt" || true
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
sleep 1
python3 -I - "$out/premain-dyld-libraries.txt" <<'PY' || true
import re, sys
rows = [l.rstrip("\n") for l in open(sys.argv[1], errors="replace")]
dy = [(float(l.split(None, 1)[0]), l.split(None, 1)[1]) for l in rows
      if re.match(r"\s*[\d.]+ .*dyld", l) and len(l.split(None, 1)) == 2]
print(f"dyld log: {len(rows)} lines, {len(dy)} dyld lines" +
      (f", first at {dy[0][0]:.0f} ms, last at {dy[-1][0]:.0f} ms after the simctl call" if dy else ""))
if dy:
    gaps = sorted(((dy[i + 1][0] - dy[i][0], dy[i + 1][1][:160]) for i in range(len(dy) - 1)), reverse=True)[:8]
    for g, what in gaps:
        print(f"dyld gap {g:.0f} ms before: {what}")
PY

mkdir -p "$out/premain-trace"
# The selected Xcode can be a release candidate whose Instruments does not load on the runner's macOS
# (Xcode 27.2 RC: `Symbol not found ... libswiftos.dylib`); record with the newest stable Xcode on the image
# when there is one, else the selected one.
xdev="$(xcode-select -p)"
for x in $(ls -d /Applications/Xcode*.app 2>/dev/null | grep -viE 'release_candidate|beta|_rc' | sort -V -r); do
  [[ -x "$x/Contents/Developer/usr/bin/xctrace" ]] && { xdev="$x/Contents/Developer"; break; }
done
echo "xctrace from $xdev" | tee "$out/premain-trace/xcode.txt"
xctrace() { DEVELOPER_DIR="$xdev" xcrun xctrace "$@"; }
if bounded 240 env DEVELOPER_DIR="$xdev" xcrun xctrace record --template 'App Launch' --device "$udid" --time-limit 15s \
     --output "$trace" --env CMUX_MOBILE_MOCK_AUTH=1 --launch -- "$app" -cmuxMobile.setupComplete YES \
     >"$out/premain-trace/record.log" 2>&1 && [[ -d "$trace" ]]; then
  xctrace export --input "$trace" --toc >"$out/premain-trace/toc.xml" 2>"$out/premain-trace/toc.err" || true
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
        bounded 120 env DEVELOPER_DIR="$xdev" xcrun xctrace export --input "$trace" \
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
for name, key in (("simctl-first-connect.json", "app"), ("simctl-first-connect-floor.json", "floor"),
                  ("simctl-first-connect-floor-webrtc.json", "floor_webrtc"),
                  ("simctl-first-connect-floor-pad.json", "floor_pad"),
                  ("simctl-first-connect-floor-rust.json", "floor_rust"),
                  ("simctl-first-connect-floor-ent.json", "floor_ent"),
                  ("simctl-first-connect-floor-dylibs.json", "floor_dylibs"),
                  ("simctl-first-connect-app-shell.json", "app_shell")):
    p = o / name
    if p.exists():
        d = json.loads(p.read_text())
        line[key] = {m: d["marks"][m]["p90_ms"] for m in ("main", "did_finish_launching", "workspaces_list_frame")
                     if m in d["marks"]}
        line[key]["spawn_lead_p90"] = d.get("spawn", {}).get("process_start_minus_simctl_call_ms", {}).get("p90")
f = line.get("floor", {}).get("main")
for k, label in (("floor_webrtc", "webrtc"), ("floor_pad", "text_size"), ("floor_rust", "rust_staticlib"),
                 ("floor_ent", "entitlements"), ("floor_dylibs", "system_dylibs"), ("app_shell", "app_bundle")):
    w = line.get(k, {}).get("main")
    if f is not None and w is not None:
        line[f"{label}_premain_ms_p90"] = w - f
s = o / "premain-sample-summary.json"
if s.exists():
    d = json.loads(s.read_text())
    line["sample"] = {"main_thread": d.get("main_thread_samples"), "main": d.get("main_in_samples"),
                      "premain_top": dict(list(d.get("premain_frames", {}).items())[:8])}
inv = o / "premain-inventory.json"
if inv.exists():
    d = json.loads(inv.read_text())
    line["text_bytes_by_lang"] = d.get("text_bytes_by_lang")
    line["inventory"] = {"executable_bytes": d["executable_bytes"], "embedded_count": d["embedded_count"],
                         "embedded_bytes": d["embedded_bytes"], "loads_count": d["loads_count"]}
print("PREMAIN " + json.dumps(line))
PY
