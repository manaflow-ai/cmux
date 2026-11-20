#!/usr/bin/env bash
# MCP tool-server fan-out of open agent chats on a published (or any) cmux NEXT build: per N open chats,
# the processes, RSS and idle CPU of each kind (`cmux mcp serve`, acpmux's *-mcp / tools-mcp, cmux-cua,
# __agent-host, __bg-run, the harness), from the build's own acpmux. Run alone on a fleet Mac:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/mcp-fanout.sh --ref SHA \
#     [--arg=app=nightly|https://...dmg|/Applications/X.app] [--arg=counts=1,5,15,30] [--arg=harness=claude,codex] \
#     [--arg=sample=60] [--arg=settle=15] [--arg=after_idle=150] [--arg=raw_at=5] [--arg=claude=2.1.303] \
#     [--arg=codex=0.163.0] [--arg=tool=mcp__cmux__cmux_exec] [--arg=idle_call=660] --timeout 5400
#   app=nightly  the newest build of the NEXT nightly feed (default); app=https://... one DMG; app=/path an installed .app
# Also the first cmux tool call's latency per chat (fresh), and at the largest N one chat's call idle_call
# seconds after its last turn (past hibernation; 0: none). The same command with another app= is the AFTER run.
# Real harnesses (npm, pinned), the stand-in model of
# scripts/cmux-next/acpmux-overhead-bench.py (no credential), an isolated acpmux daemon per (harness, N) with a
# scratch HOME; every process it starts is ended by pid. Driver and output lines: scripts/measure/mcp-fanout.py.
set -euo pipefail
app=nightly counts=1,5,15,30 harness=claude,codex sample=60 settle=15 after_idle=150 raw_at=5
claude_version=2.1.303 codex_version=0.163.0 tool=mcp__cmux__cmux_exec parallel=8 idle_call=660
for arg in "$@"; do
  case "$arg" in
    app=*) app="${arg#app=}" ;;
    counts=*) counts="${arg#counts=}" ;;
    harness=*) harness="${arg#harness=}" ;;
    sample=*) sample="${arg#sample=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    after_idle=*) after_idle="${arg#after_idle=}" ;;
    raw_at=*) raw_at="${arg#raw_at=}" ;;
    parallel=*) parallel="${arg#parallel=}" ;;
    idle_call=*) idle_call="${arg#idle_call=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    codex=*) codex_version="${arg#codex=}" ;;
    tool=*) tool="${arg#tool=}" ;;
    *) echo "mcp-fanout.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$counts" =~ ^[0-9]{1,3}(,[0-9]{1,3})*$ ]] || { echo "mcp-fanout.sh: counts=1,5,15,30" >&2; exit 2; }
[[ "$harness" =~ ^(claude|codex)(,(claude|codex))?$ ]] || { echo "mcp-fanout.sh: harness=claude,codex" >&2; exit 2; }
for v in "$sample" "$settle" "$after_idle" "$raw_at" "$parallel" "$idle_call"; do
  [[ "$v" =~ ^[0-9]{1,4}$ ]] || { echo "mcp-fanout.sh: sample/settle/after_idle/raw_at/parallel are numbers" >&2; exit 2; }
done
for v in "$claude_version" "$codex_version"; do
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "mcp-fanout.sh: versions are X.Y.Z" >&2; exit 2; }
done
[[ -z "$tool" || "$tool" =~ ^[A-Za-z0-9_]{1,128}$ ]] || { echo "mcp-fanout.sh: tool= is a tool name" >&2; exit 2; }
for t in curl python3 ps shasum; do command -v "$t" >/dev/null || { echo "MCP-FANOUT-MISSING-TOOL $t" >&2; exit 2; }; done

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$root/.build/mcp-fanout"
rm -rf "$work" && mkdir -p "$work/tools"
mnt=""
cleanup() { [[ -n "$mnt" ]] && hdiutil detach -quiet "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
echo "MCP-FANOUT-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)\" cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc) os=$(sw_vers -productVersion 2>/dev/null || uname -r) load=\"$(sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg)\""

if [[ "$app" == nightly ]]; then
  app="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  [[ "$app" == https://* ]] || { echo "MCP-FANOUT no nightly DMG in the feed" >&2; exit 3; }
fi
if [[ "$app" == https://* ]]; then
  echo "MCP-FANOUT-DMG $app"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-mcp-fanout/1 -o "$work/in.dmg" "$app"
  mnt="$work/mnt" && mkdir -p "$mnt"
  hdiutil attach "$work/in.dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null
  app="$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)"
fi
if [[ -d "$app" ]]; then
  bin="$app/Contents/Resources/bin/acpmux"
  plist="$app/Contents/Info.plist"
  version=? build=?
  if [[ -f "$plist" ]]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist" 2>/dev/null || echo ?)"
    build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist" 2>/dev/null || echo ?)"
  fi
  echo "MCP-FANOUT-APP $(basename "$app") version=$version build=$build"
elif [[ -x "$app" ]]; then
  bin="$app"  # an acpmux binary itself (a local dry run)
else
  echo "MCP-FANOUT app= is not an app, DMG URL or acpmux: $app" >&2; exit 2
fi
[[ -x "$bin" ]] || { echo "MCP-FANOUT no acpmux at $bin" >&2; exit 3; }
echo "MCP-FANOUT-ACPMUX $("$bin" --version 2>&1 | head -1)"

# A bench Mac may have no npm (cmux20-bench had none): fetch a pinned Node, checked against nodejs.org's SHASUMS256.
if ! command -v npm >/dev/null; then
  node_v=v24.22.3
  case "$(uname -m)" in
    arm64) node_arch=darwin-arm64 node_sum=ff6e17d4874b76d272212b908cc020d6e815fba5a6c7eaaa06add725840307fd ;;
    x86_64) node_arch=darwin-x64 node_sum=977614af0504c81045e7fd85596dbca0e5f951b96681516dadafedcca8c447f7 ;;
    *) echo "MCP-FANOUT-MISSING-TOOL npm (no pinned Node for $(uname -s) $(uname -m))" >&2; exit 2 ;;
  esac
  mkdir -p "$work/node"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/node/node.tar.gz" \
    "https://nodejs.org/dist/$node_v/node-$node_v-$node_arch.tar.gz"
  echo "$node_sum  $work/node/node.tar.gz" | shasum -a 256 -c - >/dev/null \
    || { echo "MCP-FANOUT node $node_v $node_arch checksum mismatch" >&2; exit 3; }
  tar -xzf "$work/node/node.tar.gz" -C "$work/node" --strip-components 1
  export PATH="$work/node/bin:$PATH"
  echo "MCP-FANOUT-NODE pinned $node_v $node_arch"
fi

npm install --prefix "$work/tools" --no-fund --no-audit \
  "@anthropic-ai/claude-code@$claude_version" "@openai/codex@$codex_version" >/dev/null
export PATH="$work/tools/node_modules/.bin:$PATH"
echo "MCP-FANOUT-BIN claude $(claude --version) codex $(codex --version)"

python3 -I "$root/scripts/measure/mcp-fanout.py" --acpmux "$bin" --harness "$harness" --counts "$counts" \
  --settle "$settle" --sample "$sample" --after-idle "$after_idle" --raw-at "$raw_at" --parallel "$parallel" \
  --tool "$tool" --idle-call "$idle_call" --json "$work/result.json"
echo "MCP-FANOUT-LOAD end $(sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg)"
