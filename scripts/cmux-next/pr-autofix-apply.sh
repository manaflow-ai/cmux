#!/usr/bin/env bash
# Applies a pull request autofix patch (cmux-next-pr-autofix.yml) to the
# checkout REPO, only when every path it touches is an output of an autofix
# repair (scripts/cmux-next/base-autofix.sh) and none is a workflow, a manifest
# or a lockfile. The push job runs this copy from the base commit, never the
# pull request's own, because the patch was made by the pull request's code.
# Prints one "applied: PATH" line per file; exits 1 and applies nothing when a
# path is refused.
#
# With --changed FILE (the pull request's changed paths, one per line) it also
# leaves out every path the pull request does not own (generated_outputs.py
# drop): formatting of a file it did not change, and an output whose inputs it
# did not change, regenerated against a newer base. Those are the base
# autofix's; pushed into a pull request they conflicted with every other one
# and a later merge could drop the base's newer rows (#21946). Prints one
# "dropped: PATH" line for each.
#
# Usage: scripts/cmux-next/pr-autofix-apply.sh PATCH REPO [--changed FILE]
set -euo pipefail
patch="$(cd "$(dirname "${1:?usage: $0 PATCH REPO [--changed FILE]}")" && pwd)/$(basename "$1")"
repo="$(cd "${2:?usage: $0 PATCH REPO [--changed FILE]}" && pwd)"
changed=""
if [[ "${3:-}" == --changed ]]; then
  changed="$(cd "$(dirname "${4:?usage: $0 PATCH REPO [--changed FILE]}")" && pwd)/$(basename "$4")"
fi

# The settings exports, from scripts/cmux-next/settings-exports.txt beside this script: the one
# list of what regenerate-settings-exports.sh writes, so `allowed` cannot drift from it by holding
# a short copy and leaving an export out of the repair push (review of #23915).
settings_exports=()
while IFS= read -r line; do settings_exports+=("$line"); done < <(
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$(dirname "${BASH_SOURCE[0]}")/settings-exports.txt")
(( ${#settings_exports[@]} )) || {
  echo "scripts/cmux-next/settings-exports.txt lists no export" >&2
  exit 1
}

allowed() { # repository-relative path -> 0 when an autofix repair writes it
  local export
  for export in "${settings_exports[@]}"; do
    [[ "$1" == "$export" ]] && return 0
  done
  case "$1" in
    .github/*|*/Cargo.lock|*/Cargo.toml|*/package.json|*.lock|*/package-lock.json|*/rust-toolchain.toml|*/node_modules/*) return 1 ;;
    Packages/macOS/CmuxNext/ci-target-graph.json) return 0 ;;
    webviews/*) return 0 ;; # page strings and vp fmt
    cmux-tui/bindings/*) return 0 ;; # SDK wire layers
    cmux-tui/crates/cmux-app-host/generated/*) return 0 ;; # the typed cmux global, scopes and ops
    web/data/cmux-shortcuts.generated.json) return 0 ;;
    plans/cmux-next/action-surfaces.json|plans/cmux-next/actions.md|plans/cmux-next/links.json) return 0 ;; # action exports
    plans/cmux-next/daemon-capabilities.json) return 0 ;; # daemon capability export
    scripts/lint-namespace-types-ratchet.txt) return 0 ;;
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
excludes=(${bot_excludes[@]+"${bot_excludes[@]}"})
if [[ -n "$changed" ]]; then
  # The ownership table sits beside this script (the base's copy, like this one).
  dropped="$(printf '%s\n' "${files[@]}" | python3 -I "$(dirname "$0")/generated_outputs.py" drop --changed "$changed")"
  kept=()
  for rel in "${files[@]}"; do
    if grep -qxF -- "$rel" <<<"$dropped"; then
      echo "dropped: $rel (the pull request did not change it or its inputs; the base autofix owns it)"
      excludes+=(--exclude="$rel")
    else
      kept+=("$rel")
    fi
  done
  (( ${#kept[@]} )) || exit 0
  files=("${kept[@]}")
fi
git -C "$repo" apply ${excludes[@]+"${excludes[@]}"} "$patch"
printf 'applied: %s\n' "${files[@]}"
