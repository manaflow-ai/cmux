#!/usr/bin/env bash
# mcp-serve-malloc-ab.sh: `cmux mcp serve`'s idle phys_footprint with macOS malloc's default mode against
# space-efficient mode (MallocSpaceEfficient=1, what acpmux now sets for the server: malloc_space.rs), on one
# signed binary, no build (goal ram-baseline: the idle app's `cmux mcp serve` held 32.2 MB, siblings of the same
# binary 8-12 MB).
#
#   scripts/measure/mcp-serve-malloc-ab.sh [dmg=nightly|URL|cmux=PATH] [rounds=5] [settle=10]
#
# Each round starts both arms in turn (interleaved, default first), sends initialize, initialized and tools/list
# as an agent harness does, waits settle seconds, then reads phys_footprint and its lifetime peak
# (proc_pid_rusage, Activity Monitor's Memory column) and closes stdin. The app is not running, so action.list
# fails and the server lists its own tools only: a lower bound on the listing's heap.
# Prints `MCP-AB arm <default|space> round <n> footprint_mb <x> peak_mb <y> tools <n>` per run and
# `MCP-AB median <arm> footprint_mb <x> peak_mb <y>`, `MCP-AB delta_mb <d>` at the end; artifacts/mcp-serve-ab.txt.
set -euo pipefail
src="nightly" rounds=5 settle=10
for arg in "$@"; do
  case "$arg" in
    dmg=*) src="${arg#dmg=}" ;;
    cmux=*) src="path:${arg#cmux=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[ "$(uname -s)" = Darwin ] || { echo "MCP-AB: macOS only (phys_footprint, MallocSpaceEfficient)" >&2; exit 2; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/mcp-serve-ab.XXXXXX")"
mnt=""
cleanup() { [ -z "$mnt" ] || hdiutil detach -force "$mnt" >/dev/null 2>&1 || true; rm -rf "$scratch"; }
trap cleanup EXIT
if [[ "$src" == path:* ]]; then
  cmux="${src#path:}"
else
  url="$src"
  if [ "$url" = nightly ]; then
    url="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
      | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  fi
  [[ "$url" == https://* ]] || { echo "MCP-AB: no DMG" >&2; exit 3; }
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-mcp-serve-ab/1 -o "$scratch/in.dmg" "$url"
  mnt="$scratch/mnt"; mkdir -p "$mnt"
  hdiutil attach "$scratch/in.dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null
  app="$(find "$mnt" -maxdepth 1 -name '*.app' | head -n 1)"
  ditto "$app/Contents/Resources/bin" "$scratch/bin"
  hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach -force "$mnt" >/dev/null 2>&1; mnt=""
  echo "MCP-AB source $url commit $(plutil -extract CMUXCommit raw -o - "$app/Contents/Info.plist" 2>/dev/null || echo '?')" || true
  cmux="$scratch/bin/cmux"
fi
[ -x "$cmux" ] || { echo "MCP-AB: no cmux binary at $cmux" >&2; exit 3; }
mkdir -p artifacts
# A home of its own: no person's settings, no app socket.
export HOME="$scratch/home"; mkdir -p "$HOME"
python3 -I - "$cmux" "$rounds" "$settle" <<'PY' | tee artifacts/mcp-serve-ab.txt
import ctypes, json, os, statistics, subprocess, sys, time
cmux, rounds, settle = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
def footprint(pid):
    buf = (ctypes.c_uint64 * 64)()  # rusage_info_v4: a 16-byte uuid, then u64 fields
    if lib.proc_pid_rusage(pid, 4, ctypes.byref(buf)) != 0:
        raise OSError(f"proc_pid_rusage {pid}")
    fields = buf[2:]  # past the uuid
    return fields[7] / 1048576, fields[28] / 1048576  # ri_phys_footprint, ri_lifetime_max_phys_footprint
def run(space):
    env = dict(os.environ)
    env.pop("MallocSpaceEfficient", None)
    if space:
        env["MallocSpaceEfficient"] = "1"; env["CMUX_MALLOC_SPACE_EFFICIENT"] = "1"
    p = subprocess.Popen([cmux, "mcp", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env)
    def ask(msg, answer=True):
        p.stdin.write((json.dumps(msg) + "\n").encode()); p.stdin.flush()
        return json.loads(p.stdout.readline()) if answer else None
    ask({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18",
         "capabilities": {}, "clientInfo": {"name": "mcp-serve-ab", "version": "1"}}})
    ask({"jsonrpc": "2.0", "method": "notifications/initialized"}, answer=False)
    tools = ask({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    n = len(tools.get("result", {}).get("tools", []))
    time.sleep(settle)
    now, peak = footprint(p.pid)
    p.stdin.close(); p.wait(timeout=10)
    return now, peak, n
rows = {"default": [], "space": []}
for r in range(1, rounds + 1):
    for arm in ("default", "space"):
        now, peak, n = run(arm == "space")
        rows[arm].append((now, peak))
        print(f"MCP-AB arm {arm} round {r} footprint_mb {now:.1f} peak_mb {peak:.1f} tools {n}", flush=True)
med = {}
for arm, vals in rows.items():
    med[arm] = statistics.median(v[0] for v in vals)
    print(f"MCP-AB median {arm} footprint_mb {med[arm]:.1f} peak_mb {statistics.median(v[1] for v in vals):.1f} "
          f"range {min(v[0] for v in vals):.1f}-{max(v[0] for v in vals):.1f}")
print(f"MCP-AB delta_mb {med['space'] - med['default']:.1f}")
PY
