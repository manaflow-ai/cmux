#!/usr/bin/env bash
# Applies a pull request autofix patch (cmux-next-pr-autofix.yml) to the
# checkout REPO, only when every path it touches is an output of an autofix
# repair (scripts/cmux-next/base-autofix.sh) and none is a workflow, a manifest
# or a lockfile. The push job runs this copy from the base commit, never the
# pull request's own, because the patch was made by the pull request's code.
# Prints one "applied: PATH" line per file; exits 1 and applies nothing when a
# path is refused.
#
# Usage: scripts/cmux-next/pr-autofix-apply.sh PATCH REPO
set -euo pipefail
patch="$(cd "$(dirname "${1:?usage: $0 PATCH REPO}")" && pwd)/$(basename "$1")"
repo="$(cd "${2:?usage: $0 PATCH REPO}" && pwd)"

allowed() { # repository-relative path -> 0 when an autofix repair writes it
  case "$1" in
    .github/*|*/Cargo.lock|*/Cargo.toml|*/package.json|*.lock|*/package-lock.json|*/rust-toolchain.toml|*/node_modules/*) return 1 ;;
    Packages/macOS/CmuxNext/ci-target-graph.json) return 0 ;;
    webviews/*) return 0 ;; # page strings and vp fmt
    cmux-tui/bindings/*) return 0 ;; # SDK wire layers
    cmux-tui/crates/cmux-app-host/generated/*) return 0 ;; # the typed cmux global, scopes and ops
    web/data/cmux-shortcuts.generated.json) return 0 ;;
    plans/cmux-next/action-surfaces.json|plans/cmux-next/actions.md|plans/cmux-next/links.json) return 0 ;; # action exports
    scripts/lint-namespace-types-ratchet.txt) return 0 ;;
    # The settings exports and their source stamp: exactly the files regenerate-settings-exports.sh writes.
    schemas/settings/settings-schema.json|schemas/settings-export/settings-schema.sources.sha256) return 0 ;;
    docs/mdm/com.manaflow.cmux.json|docs/mdm/com.manaflow.cmux.plist|docs/mdm/com.manaflow.cmux.intune.plist) return 0 ;;
    docs/mdm/cmux-example.mobileconfig|docs/mdm/managed-preferences.md) return 0 ;;
    clients/ts/cloud/src/generated.ts) return 0 ;;
    cmux-tui/crates/cmux-cloud-wire/src/generated/*) return 0 ;;
    scripts/ghosttykit-checksums.txt) return 0 ;;
    cmux-tui/*.rs|Native/OptChat/*.rs) return 0 ;; # cargo fmt
  esac
  return 1
}

# Mode changes, symlinks and renames are never a repair's output.
if git -C "$repo" apply --summary "$patch" | grep -qE 'mode change|create mode 120000|rename '; then
  echo "refused: the patch changes a file mode, adds a symlink or renames a file" >&2
  exit 1
fi
# The defaults snapshot is bot-only (#21946): the repair rewrites it, but only
# the base autofix commits it, after a merge.
bot_only=(schemas/defaults/cmux-next.json)
refused=0 files=() bot_excludes=()
while IFS=$'\t' read -r _ _ rel; do
  [[ -n "$rel" ]] || continue
  if [[ " ${bot_only[*]} " == *" $rel "* ]]; then
    echo "dropped: $rel (bot-only: the base autofix writes it after a merge)"
    bot_excludes+=(--exclude="$rel")
    continue
  fi
  if allowed "$rel"; then files+=("$rel"); else echo "refused: $rel is not an autofix output" >&2; refused=1; fi
done < <(git -C "$repo" apply --numstat "$patch")
(( refused )) && exit 1
(( ${#files[@]} )) || exit 0
git -C "$repo" apply ${bot_excludes[@]+"${bot_excludes[@]}"} "$patch"
printf 'applied: %s\n' "${files[@]}"
