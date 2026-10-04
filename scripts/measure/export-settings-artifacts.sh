#!/usr/bin/env bash
set -euo pipefail
export CMUX_UPDATE_MDM_SCHEMA=1
export CMUX_UPDATE_ACTION_SURFACES=1
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)" ./scripts/download-prebuilt-ghosttykit.sh
scripts/cmux-next/prefix-ghosttykit-archives.sh GhosttyKit.xcframework
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
