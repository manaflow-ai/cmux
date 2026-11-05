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
export GIT_TERMINAL_PROMPT=0  # a public fetch never waits on a credential prompt
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
# Only what this script writes goes before a run: OUT may be a folder the caller owns.
mkdir -p "$out" && rm -f "$out"/{result.json,report.json,report.tgz,run.log,bun-install.log,fetch.log,ocr-build.log,applied.png,fresh-home.png}
rm -f "$out"/live-apply-*.log
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

# Runs "$@" for at most $1 seconds, printing a line when it starts and ends: a setup phase that
# hangs names itself and fails the run as could-not-run instead of eating the step's timeout.
# Job control gives the phase and its watchdog each their own process group, so a timeout ends
# the phase's children (git, bun) too, and the watchdog's sleep never holds the step's output open.
bounded() {
  local seconds="$1" name="$2" started=$SECONDS pid watchdog status
  shift 2
  echo "AGENT-LOOP setup: $name"
  set -m
  "$@" & pid=$!
  ( sleep "$seconds"; kill -TERM -- "-$pid" 2>/dev/null; sleep 5; kill -KILL -- "-$pid" 2>/dev/null ) \
    </dev/null >/dev/null 2>&1 & watchdog=$!
  set +m
  wait "$pid"; status=$?
  kill -TERM -- "-$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  echo "AGENT-LOOP setup: $name exit $status in $((SECONDS - started))s"
  return "$status"
}

curl -fsSL --proto '=https' --retry 3 -A cmux-agent-loop/1 -o "$work/in.dmg" "$url" || { echo "AGENT-LOOP download failed"; exit 3; }
# The app's commit, read from the DMG before the launch: the web tree must be the one it was built from.
mkdir -p "$mount"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mount" "$work/in.dmg" >/dev/null || { echo "AGENT-LOOP mount failed"; exit 3; }
plist="$(ls -d "$mount"/*.app/Contents/Info.plist 2>/dev/null | head -n 1)"
commit="$(/usr/libexec/PlistBuddy -c 'Print CMUXCommit' "$plist" 2>/dev/null || true)"
hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
rmdir "$mount" 2>/dev/null || true
# Nightlies stamp the commit's first 7 hex: this checkout resolves it, else GitHub's commit API.
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || { echo "AGENT-LOOP the app carries no CMUXCommit (read '${commit}')"; exit 3; }
short="$commit"
if [[ ${#commit} -lt 40 ]]; then
  commit="$(git -C "$root" rev-parse -q --verify "$short^{commit}" 2>/dev/null \
    || curl -fsSL --retry 3 -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/manaflow-ai/cmux/commits/$short" 2>/dev/null || true)"
fi
[[ "$commit" =~ ^[0-9a-f]{40}$ && "$commit" == "$short"* ]] || { echo "AGENT-LOOP could not resolve CMUXCommit $short"; exit 3; }
echo "AGENT-LOOP app commit $short ($commit)"

# Setup, not part of the loop's time: the app's tree and its webviews dependencies.
t0=$SECONDS
# The commit from a local copy first (the fleet's mirror, this checkout), GitHub last.
fetch_tree() {
  local source
  git init -q "$tree" || return 1
  for source in "${CMUX_FLEET_GIT_MIRROR:-/Users/Shared/cmux-build-fleet/git/cmux.git}" "$root" https://github.com/manaflow-ai/cmux.git; do
    [[ "$source" == https://* || -d "$source" ]] || continue
    if git -C "$tree" fetch -q --depth 1 "$source" "$commit" 2>>"$out/fetch.log"; then
      echo "AGENT-LOOP tree from $source"
      git -C "$tree" -c advice.detachedHead=false checkout -q FETCH_HEAD
      return
    fi
  done
  return 1
}
bounded 600 "fetch $commit" fetch_tree || { echo "AGENT-LOOP could not fetch $commit"; tail -n 20 "$out/fetch.log" 2>/dev/null; exit 3; }
# The warm checkout's node_modules, cloned (APFS copy on write), when its lockfile is the tree's.
if [[ -d "$root/webviews/node_modules" ]] && cmp -s "$root/webviews/bun.lock" "$tree/webviews/bun.lock"; then
  cp -cR "$root/webviews/node_modules" "$tree/webviews/node_modules" 2>/dev/null \
    || { rm -rf "$tree/webviews/node_modules"; cp -R "$root/webviews/node_modules" "$tree/webviews/node_modules"; }
  echo "AGENT-LOOP webviews node_modules from this checkout (same bun.lock)"
fi
install_deps() { cd "$tree/webviews" && bun install --frozen-lockfile >"$out/bun-install.log" 2>&1; }
bounded 900 "bun install" install_deps \
  || { echo "AGENT-LOOP bun install failed (bun.lock at $commit)"; tail -n 20 "$out/bun-install.log"; exit 3; }
ocr=()
build_ocr() { swiftc -O -o "$work/ocr" scripts/e2e/ocr.swift >"$out/ocr-build.log" 2>&1; }
if command -v swiftc >/dev/null 2>&1 && bounded 300 "screen reader" build_ocr; then
  ocr=(--ocr "$work/ocr")
fi
echo "AGENT-LOOP setup $((SECONDS - t0))s"

python3 scripts/measure/agent-loop.py --dmg "$work/in.dmg" --tree "$tree" --out "$out" ${ocr[@]+"${ocr[@]}"} 2>&1 | tee "$out/run.log"
exit "${PIPESTATUS[0]}"
