#!/usr/bin/env bash
# nightly.yml publish-nightly-identity-legacy: "Generate the old feed's appcast".
# Moved out of the workflow verbatim to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
set -euo pipefail
SPARKLE_PRIVATE_KEY="$(./scripts/ci/nightly-sparkle-key.sh)"
export SPARKLE_PRIVATE_KEY
# Read from the signed app by the signing job.
[[ "$SPARKLE_MINIMUM_SYSTEM_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "no minimum system version from the signing job" >&2; exit 1; }
# One full archive, no deltas: the old feed only has to move its
# installs to the newest build. tip_appcast_linux.py writes the item
# generate_appcast writes for this DMG alone (Ed25519 is
# deterministic: the same signature as Sparkle's sign_update) from
# the tested app's Info.plist, and refuses an app whose build or
# SUPublicEDKey does not match. Then the macOS floor and the Sparkle
# channel, which the Mac appcast script added the same way.
dmg="legacy-out/${LEGACY_DMG_PREFIX}${NIGHTLY_BUILD}.dmg"
mkdir -p "$RUNNER_TEMP/plist-archive/cmux NIGHTLY.app/Contents"
cp tested-plist/Info.plist "$RUNNER_TEMP/plist-archive/cmux NIGHTLY.app/Contents/Info.plist"
(cd "$RUNNER_TEMP/plist-archive" && python3 -I -m zipfile -c "$RUNNER_TEMP/plist.zip" "cmux NIGHTLY.app")
python3 -I scripts/ci/tip_appcast_linux.py SPARKLE_PRIVATE_KEY "$dmg" "$RUNNER_TEMP/plist.zip" "cmux NIGHTLY" \
  "https://github.com/manaflow-ai/cmux/releases/download/$CHANNEL_RELEASE_TAG/" \
  "https://github.com/manaflow-ai/cmux/releases/tag/$CHANNEL_RELEASE_TAG" "$NIGHTLY_BUILD" "legacy-out/$LEGACY_APPCAST"
python3 scripts/ci/appcast_minimum_system_version.py enforce "legacy-out/$LEGACY_APPCAST" \
  --archive "$(basename "$dmg")" --minimum "$SPARKLE_MINIMUM_SYSTEM_VERSION"
python3 -I - "legacy-out/$LEGACY_APPCAST" "$SPARKLE_CHANNEL" <<'PY'
import re, sys
path, channel = sys.argv[1:]
xml = open(path, encoding="utf-8").read()
xml, count = re.subn(r"<item>", f"<item>\n            <sparkle:channel>{channel}</sparkle:channel>", xml)
if count != 1:
    sys.exit(f"expected one appcast item, found {count}")
open(path, "w", encoding="utf-8").write(xml)
PY
# Carry the change summary of cmux NEXT's item for this build.
curl -fsSL --retry 3 -A "cmux-nightly-legacy/1" -o "$RUNNER_TEMP/next-appcast.xml" "${NIGHTLY_NEXT_FEED_BASE}/${LEGACY_APPCAST}" || true
python3 -I - "legacy-out/$LEGACY_APPCAST" "$RUNNER_TEMP/next-appcast.xml" "$NIGHTLY_BUILD" <<'PY'
import re, sys
out_path, next_path, build = sys.argv[1:]
try:
    next_xml = open(next_path, encoding="utf-8").read()
except OSError:
    sys.exit(0)
for item in re.findall(r"<item>.*?</item>", next_xml, re.S):
    if f"<sparkle:version>{build}</sparkle:version>" in item:
        desc = re.search(r"<description>.*?</description>", item, re.S)
        if desc:
            xml = open(out_path, encoding="utf-8").read()
            xml = re.sub(r"\s*<description>.*?</description>", "", xml, flags=re.S)
            xml = xml.replace("</item>", desc.group(0) + "</item>", 1)
            open(out_path, "w", encoding="utf-8").write(xml)
        break
PY
# The old feed keeps its newest Nightly item and the Dev items above
# it, each tagged from its canary verdict (as cmux NEXT's feed), so a
# Mac on Nightly always has a Nightly build while Dev is ahead.
curl -fsSL --retry 3 -A "cmux-nightly-legacy/1" -o "$RUNNER_TEMP/old-feed.xml" "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"
python3 scripts/ci/nightly_next_ring.py legacy --new "legacy-out/$LEGACY_APPCAST" --current "$RUNNER_TEMP/old-feed.xml" \
  --out "legacy-out/$LEGACY_APPCAST" --mode "$DEV_RING" --verdicts-base "$NIGHTLY_NEXT_FEED_BASE"
python3 scripts/ci/nightly-next-guard.py appcast "legacy-out/$LEGACY_APPCAST"
grep -q "<sparkle:version>${NIGHTLY_BUILD}</sparkle:version>" "legacy-out/$LEGACY_APPCAST"
cat "legacy-out/$LEGACY_APPCAST"
