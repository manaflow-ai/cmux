#!/usr/bin/env bash
# Throwaway repro (goal onboarding-new-person): Open Cloud as Pane in a fresh home of the newest NEXT nightly.
#   cmux-ci run --class exclusive --label measure --display --script scripts/measure/np-open-cloud-repro.sh --ref SHA \
#     --artifact .build/np-open-cloud/report.tgz
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/np-open-cloud"
rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
  | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
[[ "$dmg" == https://* ]] || { echo "NPOC no nightly DMG in the feed"; exit 3; }
echo "NPOC dmg $dmg host $(hostname -s)"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-npoc/1 -o "$out/in.dmg" "$dmg" || { echo "NPOC download failed"; exit 3; }
GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/measure/np-open-cloud-repro.py" \
  --dmg "$out/in.dmg" --out "$out/run" 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
rm -f "$out/in.dmg"
tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
exit "$rc"
