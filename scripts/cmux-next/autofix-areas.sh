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

bot='scripts/cmux-next/(base-autofix|autofix-areas|pr-autofix)|\.github/workflows/cmux-next-(base|pr)-autofix\.yml'
area() { # key, path regex
  local on=false
  if (( all )) || grep -qE "^($2|$bot)" <<<"$changed"; then on=true; fi
  echo "$1=$on"
}
area graph 'Packages/|scripts/cmux-next/ci-target-graph\.py'
# The strings generator reads xcstrings catalogs under Packages and webviews/src, and the settings schema.
area strings 'Packages/|webviews/src/|webviews/scripts/pages/|schemas/settings/'
# The SDK generator reads the SDK schema and its own emitters.
area sdk 'cmux-tui/spec/|cmux-tui/bindings/codegen/'
# The docs shortcuts read the catalog export and the action string catalogs.
area shortcuts 'plans/cmux-next/action-surfaces\.json|Packages/macOS/CmuxNext/Sources/CmuxNextActions/|web/scripts/export-docs-shortcuts\.ts'
# The namespace lint reads the package and iOS app sources.
area ratchets 'Packages/|ios/cmux/|scripts/lint-ios-package-conventions\.sh|scripts/lint_swift_namespaces\.py|scripts/lint-namespace-types-ratchet\.txt'
area cloud 'backend/catalog/cloud-operations\.json|backend/packages/protocol/(scripts/export-(rust-)?client\.ts|src/automation-caps\.ts)|clients/ts/cloud/|cmux-tui/crates/cmux-cloud-wire/src/generated/'
area webviews 'webviews/'
area ghostty 'ghostty$|scripts/ghosttykit-checksums\.txt'
area fmt 'cmux-tui/|Native/OptChat/'
