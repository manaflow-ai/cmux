#!/usr/bin/env bash
# Decides which base-autofix repairs a change needs, for the base bot
# (cmux-next-base-autofix.yml) and the pull request job (cmux-next-pr-autofix.yml):
# reads changed repository paths on stdin and prints one key=true|false line
# per repair. A change to the autofix itself turns every repair on, as does
# --all (stdin is then ignored).
#
# Usage: git diff --name-only A B | scripts/cmux-next/autofix-areas.sh [--all]
set -euo pipefail
all=0
[[ "${1:-}" == --all ]] && all=1
changed=""
(( all )) || changed="$(cat)"

bot='scripts/cmux-next/(base-autofix|autofix-areas|autofix-clippy|pr-autofix)|\.github/workflows/cmux-next-(base|pr)-autofix\.yml'
area() { # key, path regex
  local on=false
  if (( all )) || grep -qE "^($2|$bot)" <<<"$changed"; then on=true; fi
  echo "$1=$on"
}
area graph 'Packages/|scripts/cmux-next/ci-target-graph\.py'
area capabilities 'Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint\.swift|Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/DaemonCapabilityExportTests\.swift|plans/cmux-next/daemon-capabilities\.json|scripts/cmux-next/check-daemon-capabilities-fresh\.py|scripts/cmux-next/tests/daemon-capabilities-fresh\.test\.sh'
# The strings generator reads xcstrings catalogs under Packages and webviews/src, and the settings schema.
area strings 'Packages/|webviews/src/|webviews/scripts/pages/|schemas/settings/'
# The SDK generator reads the SDK schema and its own emitters.
area sdk 'cmux-tui/spec/|cmux-tui/bindings/codegen/'
# The action exports (regenerated on a Mac: regenerate-action-exports.sh) read
# CmuxNextActions, which depends on no other target, the tests that write them,
# and for links.json the URL schemes of CmuxNextCloud's CloudConfiguration.
area actions 'Packages/macOS/CmuxNext/Sources/CmuxNextActions/|Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Config/|Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/|Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/LinkExportTests\.swift|plans/cmux-next/(action-surfaces\.json|actions\.md|links\.json)|scripts/cmux-next/regenerate-action-exports\.sh'
# The settings exports (regenerated on a Mac: regenerate-settings-exports.sh) read
# CmuxNextSettings and the two export tests. Their source stamp is derived
# (defaults_guard.py source-stamp), never committed.
area settings 'Packages/macOS/CmuxNext/Sources/CmuxNextSettings/|Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/(SettingsSchemaExportTests|ManagedPreferencesManifestTests)\.swift|schemas/settings/settings-schema\.json|docs/mdm/|scripts/cmux-next/regenerate-settings-exports\.sh|scripts/ci/defaults_guard\.py'
# The docs shortcuts read the catalog export and the action string catalogs.
area shortcuts 'plans/cmux-next/action-surfaces\.json|Packages/macOS/CmuxNext/Sources/CmuxNextActions/|web/scripts/export-docs-shortcuts\.ts|web/scripts/export-next-docs\.ts'
# The app-host generated files read the operation catalogs, the action export and the apps' fragments.
area apphost 'cmux-tui/spec/resource-operations-v2\.json|backend/catalog/cloud-operations\.json|plans/cmux-next/action-surfaces\.json|first-party-apps/|cmux-tui/crates/cmux-app-host/(tools|generated)/'
# The namespace lint reads the package and iOS app sources.
area ratchets 'Packages/|ios/cmux/|scripts/lint-ios-package-conventions\.sh|scripts/lint_swift_namespaces\.py|scripts/lint-namespace-types-ratchet\.txt'
area cloud 'backend/catalog/cloud-operations\.json|backend/packages/protocol/(scripts/export-(rust-)?client\.ts|src/automation-caps\.ts)|clients/ts/cloud/|cmux-tui/crates/cmux-cloud-wire/src/generated/'
area webviews 'webviews/'
area ghostty 'ghostty$|scripts/ghosttykit-checksums\.txt'
area fmt 'cmux-tui/|Native/OptChat/'
# cargo clippy --fix (pull request job only): the cmux-tui Rust it changes.
area clippy 'cmux-tui/.*\.rs$'
