#!/usr/bin/env bash
# Base autofix's repair of a checkout (cmux-next-base-autofix.yml): runs base-autofix.sh on REPO
# with the repairs the changed areas call for, and prints its "fixed:"/"left:" lines. It makes no
# commit and never sees the push token.
#
# The workflow's Changed areas step decides the repairs (GRAPH, STRINGS, SDK, CAPABILITIES, SHORTCUTS, APPHOST,
# ACTIONS, SETTINGS, RATCHETS, CLOUD, FMT: true or false); the Mac job hands on its verdicts
# (EXPORTS_VERIFIED, SETTINGS_VERIFIED) and its exports (EXPORTS_DIR, when it made any); the
# webviews-fmt job hands on WEBVIEWS_PATCH. The CI target graph is dumped from REPO's own manifest
# in the pinned Swift 6.2 Linux container (ci-target-graph.py).
#
# With CMUX_BASE_AUTOFIX_AGAIN=1 (base-autofix-land.sh, on a tip that moved the inputs of a held
# file) it makes only what that tip's own tree decides: the same Linux repairs. The Mac exports and
# the webviews patch were made at an older commit, so they are not applied. What is built from the
# exports (docs shortcuts, app-host files) is made from the tip's committed action exports when
# CMUX_BASE_AUTOFIX_ACTION_EXPORTS_CURRENT=1 says they are current there, and the defaults snapshot
# when CMUX_BASE_AUTOFIX_SETTINGS_EXPORTS_CURRENT=1 says the settings exports are too; otherwise
# they wait for the next run.
#
# Usage: scripts/cmux-next/base-autofix-repair.sh REPO
# CMUX_BASE_AUTOFIX_SCRIPT: the repair (default: base-autofix.sh beside this one).
# CMUX_BASE_AUTOFIX_DUMP: a command that prints REPO's package dump (default: the Swift container).
set -euo pipefail
repo="$(cd "${1:?usage: $0 REPO}" && pwd)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autofix="${CMUX_BASE_AUTOFIX_SCRIPT:-$here/base-autofix.sh}"
again="${CMUX_BASE_AUTOFIX_AGAIN:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift_dump() { # dump-package needs the Swift 6.2 tools. The checkout is mounted read-only at its
  # own path: the manifest's local package dependencies resolve outside the package directory.
  docker run --rm -v "$1:$1:ro" -w "$1/Packages/macOS/CmuxNext" \
    docker.io/library/swift@sha256:eccc7a97f9b9881d9659e2e788081fd7675f86d39793b51200bfb178398b3784 \
    swift package dump-package
}

args=()
shortcuts="${SHORTCUTS:-false}" apphost="${APPHOST:-false}"
if [[ "$again" == 1 ]]; then
  shortcuts=false apphost=false
  if [[ "${CMUX_BASE_AUTOFIX_ACTION_EXPORTS_CURRENT:-}" == 1 ]]; then
    shortcuts=true apphost=true
  else
    args+=(--unverified-exports)
  fi
  [[ "${CMUX_BASE_AUTOFIX_SETTINGS_EXPORTS_CURRENT:-}" == 1 ]] || args+=(--unverified-settings-exports)
else
  # Regenerated action and settings exports: the defaults snapshot follows both. The docs shortcuts
  # and app-host files follow the action exports only when this run regenerated them, never a
  # settings-only artifact.
  if [[ -n "${EXPORTS_DIR:-}" && -d "$EXPORTS_DIR" ]]; then
    args+=(--generated "$EXPORTS_DIR")
    [[ -d "$EXPORTS_DIR/plans/cmux-next" ]] && shortcuts=true apphost=true
  fi
  # Dependency order: the shortcuts and app-host files follow the action exports, so they wait while
  # the exports' inputs changed unverified. The defaults snapshot follows the settings exports the same way.
  [[ "${ACTIONS:-}" == true && "${EXPORTS_VERIFIED:-}" != true ]] && args+=(--unverified-exports)
  [[ "${SETTINGS:-}" == true && "${SETTINGS_VERIFIED:-}" != true ]] && args+=(--unverified-settings-exports)
  [[ -n "${WEBVIEWS_PATCH:-}" && -s "$WEBVIEWS_PATCH" ]] && args+=(--webviews-fmt-patch "$WEBVIEWS_PATCH")
fi
if [[ "${GRAPH:-}" == true ]]; then
  ${CMUX_BASE_AUTOFIX_DUMP:-swift_dump} "$repo" > "$work/package-dump.json"
  args+=(--package-dump "$work/package-dump.json")
fi
[[ "${STRINGS:-}" == true ]] && args+=(--strings)
[[ "${SDK:-}" == true ]] && args+=(--sdk)
[[ "${CAPABILITIES:-}" == true ]] && args+=(--capabilities)
[[ "$shortcuts" == true ]] && args+=(--docs-shortcuts)
[[ "$apphost" == true ]] && args+=(--app-host)
[[ "${RATCHETS:-}" == true ]] && args+=(--ratchets)
[[ "${CLOUD:-}" == true ]] && args+=(--cloud-clients)
[[ "${FMT:-}" == true ]] || args+=(--no-fmt)
"$autofix" ${args[@]+"${args[@]}"} "$repo"
