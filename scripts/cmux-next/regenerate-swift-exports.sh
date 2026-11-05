#!/usr/bin/env bash
# Rebuilds every checked-in export a cmux-next Swift test writes under
# CMUX_UPDATE_*: the action contracts, links, daemon capabilities, settings
# schema and MDM manifests, plus the CI target graph when the tree has one.
# Needs a Mac with the package toolchain. scripts/ci/next_batch.py runs it on
# a batch stack that kept one side of a conflicted export.
set -euo pipefail
# cmux-ci-warm-contract: swiftpm-v1

root="$(git rev-parse --show-toplevel)"
# cmux-next-batch.yml runs this copy from a sparse checkout of the workflow's ref: the
# library then comes from the stack being built.
warm_lib="$(dirname "${BASH_SOURCE[0]}")/lib/warm-swiftpm.sh"
[[ -f "$warm_lib" ]] || warm_lib="$root/scripts/cmux-next/lib/warm-swiftpm.sh"
# shellcheck source=scripts/cmux-next/lib/warm-swiftpm.sh
source "$warm_lib"
cmux_next_warm_build "$root/Packages/macOS/CmuxNext"
cd "$root/Packages/macOS/CmuxNext"
CMUX_UPDATE_ACTION_SURFACES=1 CMUX_UPDATE_DAEMON_CAPABILITIES=1 CMUX_UPDATE_MDM_SCHEMA=1 \
  swift test ${cmux_next_swift_args[@]+"${cmux_next_swift_args[@]}"} --skip-build \
  --filter 'ActionSurfaceParityTests|LinkExportTests|DaemonCapabilityExportTests|ManagedPreferencesManifestTests|SettingsSchemaExportTests'
cd "$root"
if [[ -f scripts/cmux-next/ci-target-graph.py ]]; then
  python3 scripts/cmux-next/ci-target-graph.py
fi
