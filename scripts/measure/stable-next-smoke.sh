#!/usr/bin/env bash
# The cmux NEXT Stable fresh-home launch smoke on a fleet worker with a console session (macOS 27,
# M4 Pro): the GUI half of stable-next.yml's smoke-27 when its owned runner has no Aqua session.
#   cmux-ci run --class exclusive --label measure --label macos-27 --label ram48 \
#     --script scripts/measure/stable-next-smoke.sh --ref SHA --arg=dmg=URL --arg=sha256=HEX \
#     --artifact .build/stable-next-smoke/report.tgz --timeout 1800
#   --arg=dmg=URL      the stable DMG (https; files-next.cmux.com or a GitHub artifact URL)
#   --arg=sha256=HEX   its expected sha256 (the DMG the sign job made)
#   --arg=signed=true  also require Gatekeeper and a stapled ticket (a Developer ID DMG)
#   --arg=resign=BUILD instead of a stable DMG, URL is a cmux NEXT nightly DMG: re-sign it ad hoc as
#                      cmux NEXT Stable here (scripts/ci/stable-next-identity.sh) and smoke that,
#                      with --arg=commit=SHA (40 hex) the build was compiled from (a dry run)
# Exit 0: the app stayed up 30 s from a fresh home with Home rendered (scripts/ci/fresh_home_launch_smoke.py).
# Exit 1: it crashed, exited or never rendered Home. Exit 3: cannot run (no Aqua session, no DMG).
# Prints STABLE-SMOKE lines: macOS, chip, verdict, sha256.
set -uo pipefail
cd "$(dirname "$0")/../.."
out=".build/stable-next-smoke"
rm -rf "$out" && mkdir -p "$out"
url="" sha="" signed=false resign="" commit=""
for arg in "$@"; do
  case "$arg" in
    dmg=*) url="${arg#dmg=}" ;;
    sha256=*) sha="${arg#sha256=}" ;;
    signed=*) signed="${arg#signed=}" ;;
    resign=*) resign="${arg#resign=}" ;;
    commit=*) commit="${arg#commit=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
case "$url" in https://*) ;; *) echo "dmg= must be an https URL" >&2; exit 2 ;; esac
chip="$(sysctl -n machdep.cpu.brand_string)"
echo "STABLE-SMOKE host $(hostname -s) chip=\"$chip\" macOS $(sw_vers -productVersion)"
case "$chip" in *M6*) echo "STABLE-SMOKE refused: never on an M6 mini" >&2; exit 3 ;; esac

curl -fsSL --proto '=https' --retry 3 -A cmux-stable-next/1 -o "$out/in.dmg" "$url" || { echo "download failed" >&2; exit 3; }
dmg="$out/in.dmg"
if [[ -n "$resign" ]]; then
  [[ "$resign" =~ ^[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "resign= needs a build number and commit=" >&2; exit 2; }
  APPLE_SIGNING_IDENTITY=- EXPECTED_COMMIT="$commit" \
    STABLE_FEED_URL=https://files-next.cmux.com/nightly-next/stable/appcast-arm64.xml \
    EXPECTED_SPARKLE_PUBLIC_KEY="IOPItMLjtc4NsROTNZ6a/jsUW+C4fcicl6SNjVVvzRM=" \
    bash scripts/ci/stable-next-identity.sh "$dmg" "$resign" "$out/app" > "$out/identity.log" 2>&1 \
    || { tail -20 "$out/identity.log"; echo "STABLE-SMOKE re-sign failed" >&2; exit 1; }
  tail -2 "$out/identity.log"
  hdiutil create -volname "cmux NEXT Stable" -srcfolder "$out/app/cmux NEXT Stable.app" -ov -format UDZO "$out/stable.dmg" -quiet
  dmg="$out/stable.dmg"
  sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
fi
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "sha256= must be 64 hex" >&2; exit 2; }

status=0
RUNNER_TEMP="$PWD/$out" GITHUB_OUTPUT="$PWD/$out/output" GITHUB_STEP_SUMMARY="$PWD/$out/summary.md" \
  DMG="$dmg" EXPECT_SHA256="$sha" SIGNED="$signed" bash scripts/ci/stable-next-smoke.sh || status=$?
tested="$(sed -n 's/^tested=//p' "$out/output" 2>/dev/null)"
verdict="$(cat "$out/summary.md" 2>/dev/null | sed -n 's/.*launch smoke on macOS [^:]*: //p' | head -1)"
echo "STABLE-SMOKE verdict=${verdict:-none} exit=$status sha256=$sha tested=${tested:-none}"
tar -czf "$out/report.tgz" -C "$out" launch-smoke summary.md 2>/dev/null || true
if grep -q 'CANNOT RUN' "$out"/launch-smoke/attempt-*/*.log 2>/dev/null || [[ "$verdict" == cannot-run ]]; then
  exit 3
fi
exit "$status"
