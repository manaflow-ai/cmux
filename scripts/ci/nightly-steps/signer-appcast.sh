#!/usr/bin/env bash
# nightly.yml signer-dmg: "Write the appcast". The item
# scripts/sparkle_generate_appcast.sh writes for the immutable DMG alone, from
# the signed app's Info.plist (stapling adds only the ticket) (scripts/ci/tip_appcast_linux.py: the same
# deterministic Ed25519 signature as Sparkle's sign_update), then the macOS
# floor and the ring tag. The signature is then checked again against the
# pinned NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY, not the key that made it.
set -euo pipefail
: "${TOOLS:?}" "${CHANNEL_APP_NAME:?}" "${NIGHTLY_DMG_IMMUTABLE:?}" "${NIGHTLY_BUILD:?}" "${FLOOR:?}" "${SPARKLE_CHANNEL:?}"
appcast="signer-out/appcast-${NIGHTLY_VARIANT}.xml"
dmg="signer-out/$NIGHTLY_DMG_IMMUTABLE"
plist_dir="$(mktemp -d "$RUNNER_TEMP/plist.XXXXXX")"
tar -C "$plist_dir" -xf signer-app/signed-app.tar "$CHANNEL_APP_NAME.app/Contents/Info.plist"
(cd "$plist_dir" && python3 -I -m zipfile -c "$RUNNER_TEMP/plist.zip" "$CHANNEL_APP_NAME.app")
SPARKLE_PRIVATE_KEY="$(bash "$TOOLS/scripts/ci/nightly-sparkle-key.sh")"
export SPARKLE_PRIVATE_KEY
# macOS ships LibreSSL, which cannot perform the generator's OpenSSL 3 Ed25519
# check. The generated signature is verified immediately afterward by the pure
# Python RFC 8032 verifier, so skip only that redundant OpenSSL check on this path.
CMUX_SKIP_OPENSSL_VERIFY=1 env -u NEXT_SPARKLE_PRIVATE_KEY python3 -I "$TOOLS/scripts/ci/tip_appcast_linux.py" SPARKLE_PRIVATE_KEY "$dmg" "$RUNNER_TEMP/plist.zip" \
  "$CHANNEL_APP_NAME" "https://github.com/manaflow-ai/cmux/releases/download/$CHANNEL_RELEASE_TAG/" \
  "https://github.com/manaflow-ai/cmux/releases/tag/$CHANNEL_RELEASE_TAG" "$NIGHTLY_BUILD" "$appcast"
unset SPARKLE_PRIVATE_KEY NEXT_SPARKLE_PRIVATE_KEY
python3 "$TOOLS/scripts/ci/appcast_minimum_system_version.py" enforce "$appcast" \
  --archive "$NIGHTLY_DMG_IMMUTABLE" --minimum "$FLOOR"
python3 -I - "$appcast" "$SPARKLE_CHANNEL" <<'PY'
import re, sys
path, channel = sys.argv[1:]
xml = open(path, encoding="utf-8").read()
xml, count = re.subn(r"<item>", f"<item>\n            <sparkle:channel>{channel}</sparkle:channel>", xml)
if count != 1:
    sys.exit(f"expected one appcast item, found {count}")
open(path, "w", encoding="utf-8").write(xml)
PY
python3 "$TOOLS/scripts/ci/nightly-next-guard.py" appcast "$appcast"
python3 -I "$TOOLS/scripts/ci/release-signer/verify_appcast_item.py" "$appcast" "$dmg" "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY" "$NIGHTLY_BUILD" \
  | tee -a "$GITHUB_STEP_SUMMARY"
