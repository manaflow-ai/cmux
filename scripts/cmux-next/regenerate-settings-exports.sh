#!/usr/bin/env bash
# Regenerates the settings exports for the CI and the autofix bots, on a Mac
# runner, the same way the fleet export step does (run-swift-testing-suites.sh
# with CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=export-settings): build, compile the
# string catalogs, then ManagedPreferencesManifestTests with
# CMUX_UPDATE_MDM_SCHEMA=1 and SettingsSchemaExportTests with
# CMUX_UPDATE_ACTION_SURFACES=1. It copies every export that changed into OUT
# at its repository path: the --generated DIR of
# scripts/cmux-next/base-autofix.sh, which copies them over the checkout and
# then rewrites the defaults snapshot (defaults_guard.py snapshot) from them.
# The exports and their source stamp
# (schemas/settings-export/settings-schema.sources.sha256, which
# defaults_guard.py check-stamp compares with the CmuxNextSettings sources)
# stay checked in; no lane regenerates them by hand.
#
# Usage: scripts/cmux-next/regenerate-settings-exports.sh OUT
# CMUX_SETTINGS_EXPORTS_ALL=1 copies every export into OUT, changed or not.
#
# An OUT that ends in .patch is a bundle, for a lane whose pull request changes
# CmuxNextSettings sources (the PR autofix only uploads a patch on
# pull_request events, and a fleet step returns one --artifact file, so a run
# with a folder handed back a single docs/mdm file). After the stamp check
# passes, it also writes the files that follow the schema: the docs settings
# reference (web/data/next-docs/settings-reference.generated.json) and the
# defaults snapshot (schemas/defaults/cmux-next.json, bot-only (#21946): drop
# it before you commit, as pr-autofix-apply.sh does). OUT is then one
# `git diff --binary` patch of every regenerated file against the step's
# commit, for `git apply --index`. The bots pass a folder. On the fleet (the
# package needs the macOS SDK, so there is no Linux route):
#   cmux-ci run --class light --script scripts/cmux-next/regenerate-settings-exports.sh \
#     --arg=settings-exports.patch --artifact settings-exports.patch --ref <full sha> --key <unique key>
#   cmux-ci artifact <step id> settings-exports.patch
set -euo pipefail
# swift test builds and runs cmux-next's test host: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-only.sh"
cmux_next_require_fleet regenerate-settings-exports.sh "swift test" "cmux-next generated files / base autofix action exports"
bundle=""
if [[ "${1:?usage: $0 OUT}" == *.patch ]]; then
  bundle="$(mkdir -p "$(dirname "$1")" && cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
else
  out="$(mkdir -p "$1" && cd "$1" && pwd)"
fi
root="$(git rev-parse --show-toplevel)"
exports=(
  docs/mdm/com.manaflow.cmux.json
  docs/mdm/com.manaflow.cmux.plist
  docs/mdm/com.manaflow.cmux.intune.plist
  docs/mdm/cmux-example.mobileconfig
  docs/mdm/managed-preferences.md
  schemas/settings/settings-schema.json
  schemas/settings-export/settings-schema.sources.sha256
)

cd "$root/Packages/macOS/CmuxNext"
swift build --build-tests
# SwiftPM copies raw catalogs but can keep old compiled tables on a reused
# runner; the exported texts come from the compiled tables.
CMUX_SWIFT_BIN_PATH="$(swift build --show-bin-path)" "$root/scripts/cmux-next/compile-string-catalogs.sh"
# The exports are written before each test compares them, so an export test
# that fails for another reason still leaves them current (and says so).
status=0
CMUX_UPDATE_MDM_SCHEMA=1 swift test --skip-build --filter ManagedPreferencesManifestTests || status=$?
CMUX_UPDATE_ACTION_SURFACES=1 swift test --skip-build --filter SettingsSchemaExportTests || status=$?
(( status == 0 )) || echo "::warning::a settings export test failed (exit $status); the exports were still regenerated"
cd "$root"
# A file the exporters wrote that this list does not name would be left stale
# by the bots while the stamp says fresh: refuse it.
listed="$(printf '%s\n' "${exports[@]}")"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  grep -qxF -- "$path" <<<"$listed" || { echo "::error::the settings export wrote $path, which regenerate-settings-exports.sh does not list" >&2; exit 1; }
done < <(git status --porcelain --untracked-files=all -- docs/mdm schemas/settings schemas/settings-export | cut -c4-)
for file in "${exports[@]}"; do
  [[ -f "$file" ]] || { echo "::error::$file was not written by the settings export" >&2; exit 1; }
  # An export that is not committed yet (the first stamp) counts as changed. With
  # CMUX_SETTINGS_EXPORTS_ALL=1 every export is copied (base-autofix-settings-exports.sh).
  if [[ "${CMUX_SETTINGS_EXPORTS_ALL:-}" != 1 ]] && git ls-files --error-unmatch -- "$file" >/dev/null 2>&1 \
    && git diff --quiet -- "$file"; then continue; fi
  mkdir -p "$out/$(dirname "$file")"
  cp "$file" "$out/$file"
  echo "regenerated: $file"
done
# The stamp must now match the sources: an export test that failed before it
# wrote leaves the stamp stale, and that is a failed regeneration, not a fresh one.
python3 scripts/ci/defaults_guard.py check-stamp
[[ -n "$bundle" ]] || exit 0
# The files that follow the schema, then one patch of everything regenerated.
followers=(web/data/next-docs/settings-reference.generated.json schemas/defaults/cmux-next.json)
if command -v bun >/dev/null 2>&1; then
  bun web/scripts/export-next-docs.ts --settings
else
  node web/scripts/export-next-docs.ts --settings # Node 22.18+ strips the types
fi
python3 scripts/ci/defaults_guard.py snapshot
git add --intent-to-add -- "${exports[@]}" "${followers[@]}"
git diff --binary HEAD -- "${exports[@]}" "${followers[@]}" > "$bundle"
echo "bundle: $bundle"
git diff --stat HEAD -- "${exports[@]}" "${followers[@]}"
