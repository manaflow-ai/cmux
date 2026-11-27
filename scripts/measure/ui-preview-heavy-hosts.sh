#!/usr/bin/env bash
# The UI preview's heavy scene hosts (Prototypes/UiLayerHost cmux-ui-home, cmux-ui-settings) on a Mac, as the worker
# runs them: no GhosttyKit fetched, one warm .build. Builds each host cold, shoots one scene of each, then times a
# one-line edit and its revert in the module each host draws (HomeEngine, SettingsWindow), twice.
#   cmux-ci test -- bash scripts/measure/ui-preview-heavy-hosts.sh
# Lines: HEAVY-HOSTS-BUILD, HEAVY-HOSTS-SHOT, HEAVY-HOSTS-EDIT (seconds), HEAVY-HOSTS-OK at the end.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pkg=Prototypes/UiLayerHost
out="$(pwd)/artifacts/heavy-hosts"
mkdir -p "$out"
echo "HEAVY-HOSTS-MACHINE sha=$(git rev-parse HEAD) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion)"
secs() { local t0; t0=$(python3 -c 'import time; print(time.time())'); "$@" >"$out/last-build.log" 2>&1 || { tail -40 "$out/last-build.log"; return 1; }; python3 -c "import time; print(round(time.time()-$t0, 2))"; }
for product in cmux-ui-layer cmux-ui-home cmux-ui-settings; do
  echo "HEAVY-HOSTS-BUILD $product cold $(secs swift build --package-path "$pkg" --product "$product")"
done
bin="$(swift build --package-path "$pkg" --show-bin-path)"
for pair in cmux-ui-layer:tabs cmux-ui-home:chief-teleport cmux-ui-settings:density-playground; do
  product="${pair%%:*}" scene="${pair#*:}"
  (cd "$pkg" && "$bin/$product" --shoot "$out/$product" --scene "$scene") | sed "s/^/HEAVY-HOSTS-SHOT $product /"
  test -s "$out/$product/$scene.png"
done
edit() { # product file
  local product="$1" file="$2"
  for round in 1 2; do
    printf '\nprivate let heavyHostsProbe%s = %s\n' "$round" "$round" >>"$file"
    echo "HEAVY-HOSTS-EDIT $product $(basename "$file") edit round=$round $(secs swift build --package-path "$pkg" --product "$product")"
    git checkout -- "$file"
    echo "HEAVY-HOSTS-EDIT $product $(basename "$file") revert round=$round $(secs swift build --package-path "$pkg" --product "$product")"
  done
}
edit cmux-ui-home Packages/macOS/CmuxNext/Sources/CmuxNextHomeEngine/ChiefTeleport/ChiefTeleportPlayground.swift
edit cmux-ui-settings Packages/macOS/CmuxNext/Sources/CmuxNextSettingsWindow/DensityPlayground/DensityPlaygroundWindow.swift
echo "HEAVY-HOSTS-OK"
