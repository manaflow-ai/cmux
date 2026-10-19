#!/usr/bin/env bash
# Applies a pull request autofix patch (cmux-next-pr-autofix.yml) to the
# checkout REPO, only when every path it touches is an output of an autofix
# repair (scripts/cmux-next/base-autofix.sh) and none is a workflow, a manifest
# or a lockfile. The push job runs this copy from the base commit, never the
# pull request's own, because the patch was made by the pull request's code.
# Prints one "applied: PATH" line per file; exits 1 and applies nothing when a
# path is refused.
#
# The repairs run over the whole merge tree, so a patch can also carry files
# the pull request does not own (#21946): vp fmt and cargo fmt of base files it
# never changed, and regenerated outputs whose inputs it never changed. Each
# such file is skipped, not refused, and reported as "skipped: PATH (why)":
#   --changed FILE     the pull request's changed paths, one per line. A
#                      formatter's output is kept only for a path in FILE; a
#                      generated output only when autofix-areas.sh turns its
#                      repair on for FILE.
#   --base-moved FILE  paths the base branch changed after the repair's merge
#                      tree was made. A generated output in FILE is skipped:
#                      the patch's copy is the older base's, and a later merge
#                      through the cmux-generated-v1 driver would keep it over
#                      the base's newer one without a conflict. The next run
#                      regenerates it from the newer merge tree.
# Without them every repair output is applied, as before.
#
# Usage: scripts/cmux-next/pr-autofix-apply.sh PATCH REPO [--changed FILE] [--base-moved FILE]
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch="$(cd "$(dirname "${1:?usage: $0 PATCH REPO}")" && pwd)/$(basename "$1")"
repo="$(cd "${2:?usage: $0 PATCH REPO}" && pwd)"
shift 2
changed_file="" moved_file=""
while (( $# )); do
  case "$1" in
    --changed) changed_file="${2:?--changed needs a file}"; shift 2 ;;
    --base-moved) moved_file="${2:?--base-moved needs a file}"; shift 2 ;;
    *) echo "usage: $0 PATCH REPO [--changed FILE] [--base-moved FILE]" >&2; exit 2 ;;
  esac
done

# repository-relative path -> the repair that writes it: "fmt" (a formatter,
# so the path must be the pull request's own), an autofix-areas.sh key, or
# "defaults"; exit 1 when no repair writes it.
repair_of() {
  case "$1" in
    .github/*|*/Cargo.lock|*/Cargo.toml|*/package.json|*.lock|*/package-lock.json|*/rust-toolchain.toml|*/node_modules/*) return 1 ;;
    Packages/macOS/CmuxNext/ci-target-graph.json) echo graph ;;
    webviews/*) echo fmt ;; # vp fmt (the page strings are build output since #21946)
    cmux-tui/bindings/*) echo sdk ;; # SDK wire layers
    cmux-tui/crates/cmux-app-host/generated/*) echo apphost ;; # the typed cmux global, scopes and ops
    web/data/cmux-shortcuts.generated.json) echo shortcuts ;;
    plans/cmux-next/action-surfaces.json|plans/cmux-next/actions.md|plans/cmux-next/links.json) echo actions ;; # action exports
    scripts/lint-namespace-types-ratchet.txt) echo ratchets ;;
    schemas/defaults/cmux-next.json) echo defaults ;; # the defaults snapshot (a changed default still needs a call)
    # The settings exports and their source stamp: exactly the files regenerate-settings-exports.sh writes.
    schemas/settings/settings-schema.json|schemas/settings-export/settings-schema.sources.sha256) echo settings ;;
    docs/mdm/com.manaflow.cmux.json|docs/mdm/com.manaflow.cmux.plist|docs/mdm/com.manaflow.cmux.intune.plist) echo settings ;;
    docs/mdm/cmux-example.mobileconfig|docs/mdm/managed-preferences.md) echo settings ;;
    clients/ts/cloud/src/generated.ts) echo cloud ;;
    cmux-tui/crates/cmux-cloud-wire/src/generated/*) echo cloud ;;
    scripts/ghosttykit-checksums.txt) echo ghostty ;;
    cmux-tui/*.rs|Native/OptChat/*.rs) echo fmt ;; # cargo fmt and clippy --fix
    *) return 1 ;;
  esac
}

# Mode changes, symlinks and renames are never a repair's output.
if git -C "$repo" apply --summary "$patch" | grep -qE 'mode change|create mode 120000|rename '; then
  echo "refused: the patch changes a file mode, adds a symlink or renames a file" >&2
  exit 1
fi
refused=0 files=() repairs=()
while IFS=$'\t' read -r _ _ rel; do
  [[ -n "$rel" ]] || continue
  if repair="$(repair_of "$rel")"; then
    files+=("$rel") repairs+=("$repair")
  else
    echo "refused: $rel is not an autofix output" >&2; refused=1
  fi
done < <(git -C "$repo" apply --numstat "$patch")
(( refused )) && exit 1
(( ${#files[@]} )) || exit 0

listed() { grep -qxF -- "$1" "$2"; } # path, file of paths
on=""
[[ -n "$changed_file" ]] && on="$(bash "$script_dir/autofix-areas.sh" < "$changed_file" | sed -n 's/=true$//p')"
area_on() { grep -qx -- "$1" <<<"$on"; }
kept=()
for i in "${!files[@]}"; do
  rel="${files[$i]}" repair="${repairs[$i]}"
  if [[ -n "$changed_file" ]]; then
    case "$repair" in
      fmt) listed "$rel" "$changed_file" || { echo "skipped: $rel (the pull request does not change it; the base bot formats it)"; continue; } ;;
      # The snapshot reads the action and settings exports and the app's Swift sources.
      defaults) { area_on actions || area_on settings || area_on graph || listed "$rel" "$changed_file"; } \
        || { echo "skipped: $rel (the pull request changes none of its inputs)"; continue; } ;;
      *) area_on "$repair" || { echo "skipped: $rel (the pull request changes none of its inputs)"; continue; } ;;
    esac
  fi
  if [[ -n "$moved_file" && "$repair" != fmt ]] && listed "$rel" "$moved_file"; then
    echo "skipped: $rel (the base changed it after the repair ran; the next run regenerates it)"
    continue
  fi
  kept+=("$rel")
done
(( ${#kept[@]} )) || exit 0
include=()
for rel in "${kept[@]}"; do include+=(--include "$rel"); done
git -C "$repo" apply "${include[@]}" "$patch"
printf 'applied: %s\n' "${kept[@]}"
