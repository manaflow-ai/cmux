#!/usr/bin/env bash
# Rebuilds every checked-in export a cmux-next Swift test writes under
# CMUX_UPDATE_*: the action contracts, links, daemon capabilities, settings
# schema and MDM manifests, plus the CI target graph when the tree has one.
# Needs a Mac with the package toolchain. scripts/ci/next_batch.py runs it on
# a batch stack that kept one side of a conflicted export.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root/Packages/macOS/CmuxNext"
swift build --build-tests
CMUX_UPDATE_ACTION_SURFACES=1 CMUX_UPDATE_DAEMON_CAPABILITIES=1 CMUX_UPDATE_MDM_SCHEMA=1 \
  swift test --skip-build \
  --filter 'ActionSurfaceParityTests|LinkExportTests|DaemonCapabilityExportTests|ManagedPreferencesManifestTests|SettingsSchemaExportTests'
cd "$root"
if [[ -f scripts/cmux-next/ci-target-graph.py ]]; then
  python3 scripts/cmux-next/ci-target-graph.py
fi
