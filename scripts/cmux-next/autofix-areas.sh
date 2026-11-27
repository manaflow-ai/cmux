#!/usr/bin/env bash
# Decides which base-autofix repairs a change needs, for the base bot
# (cmux-next-base-autofix.yml) and the pull request job (cmux-next-pr-autofix.yml):
# reads changed repository paths on stdin and prints one key=true|false line
# per repair. A change to the autofix itself turns every repair on, as does
# --all (stdin is then ignored). AUTOFIX_GATE_<KEY>=false in the environment turns
# repair KEY off (the pull request job's clippy follows the clippy check).
#
# Usage: git diff --name-only A B | scripts/cmux-next/autofix-areas.sh [--all]
set -euo pipefail
all=0
[[ "${1:-}" == --all ]] && all=1
changed=""
(( all )) || changed="$(cat)"

bot='scripts/cmux-next/(base-autofix|autofix-areas|autofix-clippy|pr-autofix)|\.github/workflows/cmux-next-(base|pr)-autofix\.yml'
area() { # key, path regex
  # tr, not ${1^^}: macOS runners resolve `env bash` to bash 3.2, which has no case expansion ("bad substitution").
  local on=false gate
  gate="AUTOFIX_GATE_$(tr '[:lower:]' '[:upper:]' <<<"$1")"
  # A caller's AUTOFIX_GATE_<KEY>=false turns the repair off whatever changed: the pull request job sets
  # AUTOFIX_GATE_CLIPPY to the clippy check's own skip clause (affected-jobs.json pull_request_skip.follows).
  if [[ "${!gate:-}" == false ]]; then echo "$1=false"; return; fi
  if (( all )) || grep -qE "^($2|$bot)" <<<"$changed"; then on=true; fi
  echo "$1=$on"
}
area graph 'Packages/|scripts/cmux-next/ci-target-graph\.py'
area capabilities 'Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint\.swift|Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/DaemonCapabilityExportTests\.swift|plans/cmux-next/daemon-capabilities\.json|scripts/cmux-next/check-daemon-capabilities-fresh\.py|scripts/cmux-next/tests/daemon-capabilities-fresh\.test\.sh'
# The strings generator reads xcstrings catalogs under Packages and webviews/src, and the settings schema.
area strings 'Packages/|webviews/src/|webviews/scripts/pages/|schemas/settings/'
# SDK bindings and the daemon ABI surface share spec inputs. The ABI checker also follows its
# implementation and build inputs; rules, fixtures and the baseline all live under spec/.
area sdk 'cmux-tui/spec/|cmux-tui/bindings/codegen/|cmux-tui/crates/cmux-api-compat/|cmux-tui/(Cargo\.(toml|lock)|rust-toolchain\.toml)$'
# The action exports (regenerated on a Mac: regenerate-action-exports.sh) read
# CmuxNextActions, the tests that write them, and for links.json the URL schemes
# of CmuxNextCloud's CloudConfiguration. CmuxNextActions reads the Rust catalog
# through the pinned CCmuxAppFFI, so a re-pin is an input too: the pseudo path
# Package.swift#CCmuxAppFFI, which base-autofix-ffi-pin.sh adds when the pin
# moved (the rest of Package.swift is not an input).
area actions 'Packages/macOS/CmuxNext/Package\.swift#CCmuxAppFFI|Packages/macOS/CmuxNext/Sources/CmuxNextActions/|Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Config/|Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/|Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/LinkExportTests\.swift|plans/cmux-next/(action-surfaces\.json|action-catalog\.json|actions\.md|links\.json)|scripts/cmux-next/regenerate-action-exports\.sh'
# The settings exports (regenerated on Linux: regenerate-settings-exports-linux.sh, or a Mac) read
# CmuxNextSettings and the two export tests. Their source stamp is derived
# (defaults_guard.py source-stamp), never committed.
area settings 'schemas/settings/(source|generator)/|schemas/settings/retired-keys\.json|Packages/macOS/CmuxNext/Sources/CmuxNextSettings(Export)?/|Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/(SettingsSchemaExportTests|ManagedPreferencesManifestTests)\.swift|schemas/settings/settings-schema\.json|docs/mdm/|scripts/cmux-next/regenerate-settings-exports(-linux)?\.sh|scripts/cmux-next/export-settings-linux\.sh|scripts/cmux-next/linux-exports/|scripts/ci/defaults_guard\.py'
# The docs shortcuts read the catalog export and the action string catalogs.
area shortcuts 'plans/cmux-next/action-surfaces\.json|Packages/macOS/CmuxNext/Sources/CmuxNextActions/|web/scripts/export-docs-shortcuts\.ts|web/scripts/export-next-docs\.ts'
# The app-host generated files read the operation catalogs, the action export and the apps' fragments;
# their bundled copies (sync-app-runtime.sh) also read the samples and the scope classes.
area apphost 'cmux-tui/spec/resource-operations-v2\.json|backend/catalog/cloud-operations\.json|plans/cmux-next/action-surfaces\.json|first-party-apps/|cmux-tui/crates/cmux-app-host/(tools|generated|schema)/|samples/apps/|Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/|scripts/cmux-next/sync-app-runtime\.sh'
# The namespace lint reads the package and iOS app sources.
area ratchets 'Packages/|ios/cmux/|scripts/lint-ios-package-conventions\.sh|scripts/lint_swift_namespaces\.py|scripts/lint-namespace-types-ratchet\.txt|scripts/lint-namespace-types-baseline\.txt|scripts/lint-ios-package-conventions-baseline\.txt'
area cloud 'backend/catalog/cloud-operations\.json|backend/packages/protocol/(scripts/export-(rust-)?client\.ts|src/automation-caps\.ts)|clients/ts/cloud/|cmux-tui/crates/cmux-cloud-wire/src/generated/'
# webviews formatting, and the acpmux protocol types its codegen writes from the spec.
area webviews 'webviews/|cmux-tui/crates/acpmux/spec/'
area ghostty 'ghostty$|scripts/ghosttykit-checksums\.txt'
area fmt 'cmux-tui/|Native/OptChat/'
# Every tracked Cargo.lock against its manifests (cargo-locks.py): any Cargo.toml or Cargo.lock anywhere, since a
# manifest reaches other workspaces' locks through path dependencies (eb4f3eb1d94).
area locks '(.*/)?Cargo\.(toml|lock)$'
# The acpmux protocol IR and ABI surface (base-autofix.sh --acpmux-ir): everything the IR is made of lives in the
# acpmux crate, plus schemars in the lockfile (cmux-tui-spec.yml acpmux-protocol-ir); the surface check is
# cmux-api-compat's.
area acpmuxir 'cmux-tui/crates/(acpmux|cmux-api-compat)/|cmux-tui/Cargo\.lock$'
# cargo clippy --fix: the cmux-tui Rust a pull request changes, and on the base what changed since the
# last successful run (base-autofix-repair.sh, with the crates it can affect: cargo_affected.py).
area clippy 'cmux-tui/.*\.rs$'
# The iPhone app's uniffi Swift bindings (scripts/ios-ffi-bindings.sh): the FFI crate, the crates it
# builds on, their workspace, and the committed copy itself (a merge that kept one side).
area iosffi 'cmux-next-ios/rust/(Cargo\.(toml|lock)|rust-toolchain\.toml|crates/)|cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/|scripts/ios-ffi-bindings\.sh'
area jobinputs '\.github/workflows/|scripts/ci/(fast-check-inputs|affected-jobs|job-inputs-always|pr_router)\.json$|scripts/ci/job_inputs\.py$'
