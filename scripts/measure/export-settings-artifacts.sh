#!/usr/bin/env bash
set -euo pipefail
# Build with the CI's pinned Xcode (scripts/ci/xcode-pins.txt, or CMUX_CI_XCODE_APP), as the
# package-test lane does, not the mini's default: a newer default Xcode can fail to compile test
# targets these generators never run.
if [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_env="$(mktemp)"
  GITHUB_ENV="$xcode_env" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$xcode_env" | tail -n 1)"
  rm -f "$xcode_env"
  test -n "$DEVELOPER_DIR"
  export DEVELOPER_DIR
fi
echo "Xcode: $DEVELOPER_DIR"
export CMUX_UPDATE_MDM_SCHEMA=1
export CMUX_UPDATE_ACTION_SURFACES=1
swift test --package-path Packages/macOS/CmuxNext --filter ManagedPreferencesManifestTests
swift test --package-path Packages/macOS/CmuxNext --filter SettingsSchemaExportTests
for file in \
  docs/mdm/com.manaflow.cmux.json \
  docs/mdm/com.manaflow.cmux.plist \
  docs/mdm/managed-preferences.md \
  schemas/settings/settings-schema.json; do
  echo "BEGIN_ARTIFACT:$file"
  base64 < "$file" | tr -d '\n'
  echo
  echo "END_ARTIFACT:$file"
done
