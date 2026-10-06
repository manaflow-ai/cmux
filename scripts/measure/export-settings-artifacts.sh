#!/usr/bin/env bash
set -euo pipefail
export CMUX_UPDATE_MDM_SCHEMA=1
export CMUX_UPDATE_ACTION_SURFACES=1
swift test --package-path Packages/macOS/CmuxNext --filter ManagedPreferencesManifestTests
swift test --package-path Packages/macOS/CmuxNext --filter SettingsSchemaExportTests
CMUX_UPDATE_ACTION_SURFACES=1 swift test --package-path Packages/macOS/CmuxNext --filter ActionSurfaceParityTests || true
python3 scripts/cmux-next/ci-target-graph.py
for file in plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md Packages/macOS/CmuxNext/ci-target-graph.json; do
  echo "BEGIN_ARTIFACT:$file"
  base64 < "$file" | tr -d '\n'
  echo
  echo "END_ARTIFACT:$file"
done
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
