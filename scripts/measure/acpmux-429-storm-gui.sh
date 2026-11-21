#!/usr/bin/env bash
# The acpmux 429 storm on a published cmux NEXT app's own chat pane, alone on a fleet display Mac
# (scripts/measure/acpmux-429-storm-gui.py does the run; scripts/cmux-next/acpmux_429_storm.py is the storm):
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/acpmux-429-storm-gui.sh --ref <sha> [--arg=app=nightly|https://...dmg] \
#     [--arg=agents=7] [--arg=interval=15] [--arg=storm=600] [--arg=retry_after=none|60] [--arg=settle=900] \
#     [--arg=quiet=240] [--arg=shot_every=20] [--arg=after=90] [--arg=claude=2.1.310] \
#     --artifact .build/acpmux-429-storm-gui/report.tgz --timeout 3600
#   app=nightly  the newest build of the NEXT nightly feed (default); app=https://... one DMG
# The app runs as a copy from a fresh home (fresh_home_launch_smoke.py), never an installed app; Claude Code is
# installed pinned under this step (npm; a pinned Node when the Mac has none) and talks only to the storm's local
# fake endpoint (no credential). Prints STORM-GUI lines; report.tgz holds result.json, shots/*.png and their text.
set -euo pipefail
app=nightly agents=7 interval=15 storm=600 retry_after=none settle=900 quiet=240 shot_every=20 after=90
claude_version=2.1.310
for arg in "$@"; do
  case "$arg" in
    app=*) app="${arg#app=}" ;;
    agents=*) agents="${arg#agents=}" ;;
    interval=*) interval="${arg#interval=}" ;;
    storm=*) storm="${arg#storm=}" ;;
    retry_after=*) retry_after="${arg#retry_after=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    quiet=*) quiet="${arg#quiet=}" ;;
    shot_every=*) shot_every="${arg#shot_every=}" ;;
    after=*) after="${arg#after=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    *) echo "acpmux-429-storm-gui.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
for v in "$agents" "$interval" "$storm" "$settle" "$quiet" "$shot_every" "$after"; do
  [[ "$v" =~ ^[0-9]{1,4}$ ]] || { echo "acpmux-429-storm-gui.sh: agents/interval/storm/settle/quiet/shot_every/after are numbers" >&2; exit 2; }
done
[[ "$retry_after" == none || "$retry_after" =~ ^[0-9]{1,4}$ ]] || { echo "acpmux-429-storm-gui.sh: retry_after=none|N" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "acpmux-429-storm-gui.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$app" == nightly || "$app" == https://* ]] || { echo "acpmux-429-storm-gui.sh: app=nightly|https://...dmg" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "STORM-GUI runs only on macOS" >&2; exit 2; }

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/.build/acpmux-429-storm-gui"
work="$(mktemp -d "${TMPDIR:-/tmp}/storm-gui.XXXXXX")"
rm -rf "$out" && mkdir -p "$out"
cleanup() {
  rm -rf "$work"
  tar -czf "$work.tgz" -C "$out" . 2>/dev/null && mv "$work.tgz" "$out/report.tgz" || true
}
trap cleanup EXIT
echo "STORM-GUI-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) os=$(sw_vers -productVersion) load=\"$(sysctl -n vm.loadavg)\""

if [[ "$app" == nightly ]]; then
  app="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  [[ "$app" == https://* ]] || { echo "STORM-GUI no nightly DMG in the feed" >&2; exit 3; }
fi
echo "STORM-GUI-DMG $app"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-storm-gui/1 -o "$work/in.dmg" "$app"

# A bench Mac may have no npm: a pinned Node, checked against nodejs.org's SHASUMS256 (as mcp-fanout.sh).
if ! command -v npm >/dev/null; then
  node_v=v24.22.3
  case "$(uname -m)" in
    arm64) node_arch=darwin-arm64 node_sum=ff6e17d4874b76d272212b908cc020d6e815fba5a6c7eaaa06add725840307fd ;;
    x86_64) node_arch=darwin-x64 node_sum=977614af0504c81045e7fd85596dbca0e5f951b96681516dadafedcca8c447f7 ;;
    *) echo "STORM-GUI-MISSING-TOOL npm" >&2; exit 2 ;;
  esac
  mkdir -p "$work/node"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/node/node.tar.gz" \
    "https://nodejs.org/dist/$node_v/node-$node_v-$node_arch.tar.gz"
  echo "$node_sum  $work/node/node.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "STORM-GUI node checksum mismatch" >&2; exit 3; }
  tar -xzf "$work/node/node.tar.gz" -C "$work/node" --strip-components 1
  export PATH="$work/node/bin:$PATH"
fi
mkdir -p "$work/tools"
npm install --prefix "$work/tools" --no-fund --no-audit "@anthropic-ai/claude-code@$claude_version" >/dev/null
export PATH="$work/tools/node_modules/.bin:$PATH"
echo "STORM-GUI-BIN claude $(claude --version)"

ocr=()
if command -v swiftc >/dev/null && swiftc -O -o "$work/ocr" "$root/scripts/e2e/ocr.swift" >"$out/ocr-build.log" 2>&1; then
  ocr=(--ocr "$work/ocr")
fi

python3 "$root/scripts/measure/acpmux-429-storm-gui.py" --dmg "$work/in.dmg" --out "$out" ${ocr[@]+"${ocr[@]}"} \
  --agents "$agents" --interval "$interval" --storm "$storm" --retry-after "$retry_after" --settle "$settle" \
  --quiet "$quiet" --shot-every "$shot_every" --after "$after" --label "gui-ra-$retry_after" 2>&1 | tee "$out/run.log"
exit "${PIPESTATUS[0]}"
