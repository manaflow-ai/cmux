#!/usr/bin/env bash
# The agent loop on the newest published cmux NEXT NIGHTLY (hq#7149 L8; scripts/measure/agent-loop.py
# does the loop): a scripted UI change applied live to the running app and probed, no full build.
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/agent-loop.sh --ref <sha> [--arg=dmg=URL] \
#     --artifact .build/agent-loop/report.tgz --timeout 2400
#   dmg=URL  an https NIGHTLY DMG (default: the newest item of the NEXT nightly feed)
#   out=DIR  where result.json, the logs and report.tgz go (default: .build/agent-loop)
# A GitHub Mac job runs it through scripts/ci/frame-pacing/console-session.sh, which may run it as
# the console user: so it writes only to its own temp folder and OUT, and fetches the app's commit
# into a scratch repository of its own, never into this checkout.
# Needs a console session, git (it fetches the app's commit from GitHub), bun and node for the web
# bundles (build-web-bundles.sh), and swiftc for the screen reader (evidence only; without it the
# probe still runs). Prints one AGENT-LOOP line and keeps result.json and the logs in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
out="$root/.build/agent-loop"
feed="https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
url=""
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) url="${arg#dmg=}" ;;
    out=/*) out="${arg#out=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
rm -rf "$out" && mkdir -p "$out"
if [[ -z "$url" ]]; then
  url="$(curl -fsSL --retry 3 -H 'Cache-Control: no-cache' "$feed" | grep -o -E 'enclosure url="https://[^"]+\.dmg"' | head -n 1 | cut -d'"' -f2)"
  [[ -n "$url" ]] || { echo "AGENT-LOOP no DMG in $feed"; exit 3; }
fi
echo "AGENT-LOOP host $(hostname -s) macOS $(sw_vers -productVersion) dmg $url"
work="$(mktemp -d "${TMPDIR:-/tmp}/agent-loop.XXXXXX")"
tree="$work/tree" mount="$work/mnt"
cleanup() {
  [[ -d "$mount" ]] && { hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true; }
  rm -rf "$work"
  tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
}
trap cleanup EXIT

curl -fsSL --proto '=https' --retry 3 -A cmux-agent-loop/1 -o "$work/in.dmg" "$url" || { echo "AGENT-LOOP download failed"; exit 3; }
# The app's commit, read from the DMG before the launch: the web tree must be the one it was built from.
mkdir -p "$mount"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mount" "$work/in.dmg" >/dev/null || { echo "AGENT-LOOP mount failed"; exit 3; }
plist="$(ls -d "$mount"/*.app/Contents/Info.plist 2>/dev/null | head -n 1)"
commit="$(/usr/libexec/PlistBuddy -c 'Print CMUXCommit' "$plist" 2>/dev/null || true)"
hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
rmdir "$mount" 2>/dev/null || true
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "AGENT-LOOP the app carries no CMUXCommit"; exit 3; }
echo "AGENT-LOOP app commit $commit"

# Setup, not part of the loop's time: the app's tree and its webviews dependencies.
t0=$SECONDS
{ git init -q "$tree" && git -C "$tree" fetch -q --depth 1 https://github.com/manaflow-ai/cmux.git "$commit" \
  && git -C "$tree" -c advice.detachedHead=false checkout -q FETCH_HEAD; } || { echo "AGENT-LOOP could not fetch $commit"; exit 3; }
(cd "$tree/webviews" && bun install --frozen-lockfile >"$out/bun-install.log" 2>&1) \
  || { echo "AGENT-LOOP bun install failed (bun.lock at $commit)"; tail -n 20 "$out/bun-install.log"; exit 3; }
ocr=()
if command -v swiftc >/dev/null 2>&1 && swiftc -O -o "$work/ocr" scripts/e2e/ocr.swift >"$out/ocr-build.log" 2>&1; then
  ocr=(--ocr "$work/ocr")
fi
echo "AGENT-LOOP setup $((SECONDS - t0))s"

python3 scripts/measure/agent-loop.py --dmg "$work/in.dmg" --tree "$tree" --out "$out" ${ocr[@]+"${ocr[@]}"} 2>&1 | tee "$out/run.log"
exit "${PIPESTATUS[0]}"
