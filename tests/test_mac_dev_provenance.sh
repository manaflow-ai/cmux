#!/usr/bin/env bash
set -euo pipefail

# Portable regression coverage for the Mac/iOS exact-head pairing contract.
# This test intentionally does not invoke Xcode or launch an app; it checks the
# checked-in plist/build-setting wiring that a tagged Mac reload consumes.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
with (root / "Resources/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CMUXGitSHA"] == "$(CMUX_GIT_SHA)", info["CMUXGitSHA"]
assert info["CMUXDevTag"] == "$(CMUX_DEV_TAG)", info["CMUXDevTag"]

project = (root / "cmux.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
for configuration in ("Debug", "Release"):
    block = re.search(
        rf"name = {configuration};\n\t\t\}};\n",
        project,
    )
    assert block, f"could not find {configuration} configuration"

# Defaults are blank in both configurations; reload.sh supplies values only
# for Debug, so production/TestFlight products cannot inherit a dogfood tag.
assert project.count('CMUX_DEV_TAG = "";') == 2
assert project.count('CMUX_GIT_SHA = "";') == 2

reload = (root / "scripts/reload.sh").read_text(encoding="utf-8")
assert 'git -C "$SCRIPT_DIR/.." rev-parse --short HEAD' in reload
assert 'git -C "$SCRIPT_DIR/.." status --porcelain' in reload
assert 'CMUX_GIT_SHA="$CMUX_GIT_SHA_VALUE"' in reload
assert 'CMUX_DEV_TAG="$TAG"' in reload

debug_guard = re.search(
    r'if \[\[ "\$BUILD_CONFIGURATION" == Debug \]\]; then\n'
    r'  XCODEBUILD_ARGS\+=\(\n'
    r'    CMUX_GIT_SHA="\$CMUX_GIT_SHA_VALUE"\n'
    r'    CMUX_DEV_TAG="\$TAG"\n'
    r'  \)\n'
    r'fi\nif \[\[ "\$BUILD_CONFIGURATION" == Release \]\]; then',
    reload,
)
assert debug_guard, "provenance overrides must be scoped to Debug before Release handling"
print("PASS: Mac DEV provenance is wired to Debug checkout/tag and blank for Release")
PY
