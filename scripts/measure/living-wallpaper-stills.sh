#!/usr/bin/env bash
# Fleet entry: renders stills of the calm living wallpapers with real Metal (a Mac's GPU) and packs
# them for a pull request's previews. Argument: the shaders and times, `name:seconds[,seconds]`
# (default: the six calm ones at 60 s and 120 s). Light and dark, 1280x800, pointer at rest.
#   cmux-ci run --class exclusive --label measure --script scripts/measure/living-wallpaper-stills.sh --ref <sha> --artifact artifacts/living-wallpapers.tgz
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
dir=Packages/macOS/CmuxNext/Sources/CmuxNextDesign
out="$(mktemp -d)"
trap 'rm -rf -- "$out"' EXIT
python3 - "$dir" "$out/all.metal" <<'PY'
import re, sys
base = open(sys.argv[1] + "/BackdropShaderSource.swift").read()
calm = open(sys.argv[1] + "/BackdropShaderSource+Calm.swift").read()
pick = lambda s: re.search(r'#"""\n(.*?)\n\s*"""#', s, re.S).group(1)
open(sys.argv[2], "w").write(pick(base) + "\n" + pick(calm) + "\n")
PY
specs=("$@")
[ ${#specs[@]} -gt 0 ] || specs=(sakura:60,120 sumi:60,120 koi:60,120 snowfall:60,120 lanterns:60,120 rain:60,120)
swift scripts/measure/living-wallpaper-stills.swift "$out/all.metal" "$out/stills" 1280 800 "${specs[@]}"
mkdir -p artifacts
tar -czf artifacts/living-wallpapers.tgz -C "$out" stills
cp -R "$out/stills" "${FAST_CHECKS_OUT:-artifacts}/" 2>/dev/null || true
ls "$out/stills"
