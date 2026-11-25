#!/usr/bin/env bash
# First-time Codex (ChatGPT) sign-in of the newest cmux NEXT NIGHTLY on a fleet Mac with a console session, watched
# for main-thread hangs (scripts/cmux-next/codex-login-hang.py drives it; measurement only, no account is signed in).
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/codex-login-hang.sh --ref <sha> [--arg=rounds=2] [--arg=flows=settings,onboarding] \
#     --artifact .build/codex-login-hang/report.tgz --timeout 1800
# Each round is a fresh install and a fresh home (a cold launch, the first browser tab of the launch).
# Prints STEP, PING, SAMPLE and SUMMARY lines and each sample's heaviest main-thread frames; report.tgz keeps it all.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/codex-login-hang"
rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
rounds=1 flows=settings,onboarding
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    flows=*) flows="${arg#flows=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
echo "CLH host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) user $(id -un)"
dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
  | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
[[ "$dmg" == https://* ]] || { echo "CLH no nightly DMG in the feed"; exit 3; }
echo "CLH dmg $dmg"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-codex-login-hang/1 -o "$out/in.dmg" "$dmg" || { echo "CLH download failed"; exit 3; }
swiftc -O -o "$out/ax-press" scripts/cmux-next/ax-press.swift >"$out/swiftc.log" 2>&1 || { echo "CLH ax-press build failed"; cat "$out/swiftc.log"; exit 3; }
echo "CLH ax grant: $("$out/ax-press" 1 trusted)"

# Where a codex CLI is for the app (the fresh home's PATH is only /usr/bin:/bin:...): the runner's, else an npm install.
extra=""
for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.npm-global/bin"; do
  [[ -x "$dir/codex" ]] && { extra="$dir"; break; }
done
if [[ -z "$extra" ]] && command -v npm >/dev/null; then
  npm install --silent --prefix "$out/npm" @openai/codex >"$out/npm.log" 2>&1 && extra="$out/npm/node_modules/.bin"
fi
node_dir="$(dirname "$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)")"
echo "CLH codex at ${extra:-none} ($([[ -n "$extra" ]] && "$extra/codex" --version 2>&1 | head -1)), node at $node_dir"

source scripts/ci/lib/signing-runtime-guard.sh
cmux_signing_runtime_guard || exit 3
status=0
IFS=, read -ra flow_list <<<"$flows"
for ((r = 1; r <= rounds; r++)); do
  for flow in "${flow_list[@]}"; do
    dir="$out/round-$r-$flow"
    mkdir -p "$dir" && chmod 0777 "$dir"
    echo "CLH ==> round $r flow $flow"
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/cmux-next/codex-login-hang.py" \
      --dmg "$out/in.dmg" --out "$dir" --ax "$out/ax-press" --flow "$flow" --extra-path "${extra:+$extra:}$node_dir" 2>&1 | tee "$dir/run.log"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || status=1
    log show --start "$since" --style compact --predicate 'category == "app.hangs" OR (subsystem BEGINSWITH "com.cmuxterm" AND eventMessage CONTAINS[c] "hang")' \
      >"$dir/unified-hangs.log" 2>&1 || true
    echo "CLH unified log app.hangs lines: $(grep -c . "$dir/unified-hangs.log")"; tail -n 20 "$dir/unified-hangs.log"
    for f in "$dir"/hangs/*; do [[ -f "$f" ]] && { echo "CLH --- hang file $(basename "$f")"; head -n 120 "$f"; }; done
    for sample in "$dir"/sample-*.txt; do
      [[ -f "$sample" ]] || continue
      echo "CLH --- $(basename "$sample"): heaviest frames (sort by top of stack)"
      awk '/Sort by top of stack/{on=1;next} on&&NF==0{exit} on' "$sample" | head -n 25
      echo "CLH --- $(basename "$sample"): main thread call graph"
      awk '/Call graph:/{on=1;next} on&&/^ *[0-9]+ Thread_/{n++} n>1{exit} on' "$sample" | cut -c1-240 | head -n 140
    done
  done
done
rm -f "$out/in.dmg"
tar -czf "$out.tgz" -C "$out" --exclude npm . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
exit "$status"
