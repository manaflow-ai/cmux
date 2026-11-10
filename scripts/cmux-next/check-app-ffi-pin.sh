#!/usr/bin/env bash
# Checks the app FFI pin (CCmuxAppFFI: the remote desktop core and the sidebar
# layout reducer over one Rust runtime) in Packages/macOS/CmuxNext/Package.swift.
#
#   scripts/cmux-next/check-app-ffi-pin.sh [--verify-release] [--base REF] [--tree DIR]
#   scripts/cmux-next/check-app-ffi-pin.sh --list-inputs [--tree DIR]
#
# Fails when the FFI sources at HEAD differ from the pinned source sha (the tag
# is cmux-app-ffi-<source sha>): change the Rust code, let
# .github/workflows/app-ffi-release.yml publish the new release, then pin its
# URL and checksum in one commit. With --verify-release it also downloads the
# release's SOURCE_SHA and SHA256SUMS anonymously and fails unless they name
# the pinned sha and the pinned checksum.
#
# --tree DIR checks the repository at DIR (its Package.swift, its FFI sources,
# its git history) instead of the one this script is in. The pin reader is
# always this script's own copy. cmux-next.yml runs the base's copy of both
# against a pull request's tree, so the pull request's own copy never decides
# its pin verdict.
set -euo pipefail

verify=0
list_inputs=0
base_ref=""
tree=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-release) verify=1 ;;
    --base) base_ref="${2:?--base needs a ref}"; shift ;;
    --list-inputs) list_inputs=1 ;;
    --tree) tree="${2:?--tree needs a directory}"; shift ;;
    *) echo "usage: $0 [--verify-release] [--base REF] [--tree DIR]" >&2; exit 2 ;;
  esac
  shift
done

# code: the repository this script is in, whose pin reader runs. root: the tree it checks.
code="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
root="$code"
if [[ -n "$tree" ]]; then
  root="$(cd "$tree" 2>/dev/null && pwd -P)" || { echo "error: --tree $tree is not a directory" >&2; exit 2; }
fi
manifest="$root/Packages/macOS/CmuxNext/Package.swift"
# The JSON pin (cmux#37645): when the tree has it, the pin is that file's and Package.swift holds only its loader block.
pin_file="$root/Packages/macOS/CmuxNext/app-ffi-pin.json"
asset="CCmuxAppFFI.xcframework.zip"

# The pin is read only through scripts/ci/app_ffi_pin.py's fail-closed canonical match (the classifier, the repin
# picker and the repin script read it the same way). A Package.swift whose pin is not the canonical block fails here,
# naming its first line that does not match.
pin_reader="$code/scripts/ci/app_ffi_pin.py"
workspace_manifest=cmux-tui/Cargo.toml
# The FFI sources (app_ffi_pin.py walk, fail-closed): cmux-app-ffi and every crate it reaches (cmux-rd-ffi pulls
# cmux-remote-browser, which a hand list missed on 2026-10-07), each as a whole directory except its tests/, benches/
# and examples/, plus every file outside a crate that a crate's source names (design-tokens.json, which cmux-motion's
# build script compiles in). A file only tests read is left out only through the reviewed app_ffi_pin.py TEST_ONLY
# list: #39027 changed bindings/rust/.cmux-resource-api.json, which only a test reads, and staled the pin on
# 2026-11-09. Derived from the tree at HEAD in one python3 call: the crates, a line "--", then the git pathspecs (an
# excluded directory is a `:(exclude)` pathspec).
listed_err="$(mktemp)"
if ! listed="$(python3 -I "$pin_reader" inputs "$root" 2>"$listed_err")"; then
  echo "error: the app FFI inputs cannot be listed: $(sed 's/^error: //' "$listed_err" | tail -1)" >&2
  rm -f "$listed_err"
  exit 1
fi
rm -f "$listed_err"
crates=()
paths=()
section=crates
while IFS= read -r input; do
  [[ -n "$input" ]] || continue
  if [[ "$input" == -- ]]; then section=paths; continue; fi
  if [[ "$section" == crates ]]; then crates+=("$input"); else paths+=("$input"); fi
done <<<"$listed"
# Above the crates: the cargo configs and toolchain files cargo and rustup read in and above
# cmux-tui/crates/cmux-app-ffi, where build-app-ffi.sh builds.
paths+=(cmux-tui/.cargo cmux-tui/rust-toolchain cmux-tui/rust-toolchain.toml
  cmux-tui/crates/.cargo cmux-tui/crates/rust-toolchain cmux-tui/crates/rust-toolchain.toml
  .cargo rust-toolchain rust-toolchain.toml scripts/cmux-next/build-app-ffi.sh)
# The cmux-tui workspace manifest: while cmux-app-ffi has its own [workspace] table (cargo builds it as its own
# workspace root, with its own [patch], [profile] and Cargo.lock), only what the crates inherit of it is an input
# (workspace_view below; app_ffi_pin.py workspace-view). Without that table cmux-app-ffi builds in the cmux-tui
# workspace, so the whole manifest and the cmux-tui Cargo.lock are inputs.
if ! own_root="$(python3 -I "$pin_reader" own-root "$root/cmux-tui/crates/cmux-app-ffi/Cargo.toml")"; then
  echo "error: the app FFI inputs cannot be listed: cmux-tui/crates/cmux-app-ffi/Cargo.toml cannot be read (above)" >&2
  exit 1
fi
narrowed=0
if [[ "$own_root" == yes ]]; then
  narrowed=1
else
  paths+=("$workspace_manifest" cmux-tui/Cargo.lock)
fi
# --list-inputs prints them and the workspace manifest (tests/app-ffi-release-paths.test.sh keeps the release
# workflow's push paths in step with this list: a release run on any change to the manifest is cheap and safe).
if [[ "$list_inputs" -eq 1 ]]; then
  printf '%s\n' "${paths[@]}"
  [[ "$narrowed" -eq 1 ]] && printf '%s\n' "$workspace_manifest"
  exit 0
fi

# Every python3 here runs isolated (-I): neither the script's directory nor the working directory is on its import
# path, and PYTHONPATH and the user site are ignored. Otherwise a module a change adds (scripts/ci/json.py beside the
# reader, or json.py at the root for the python3 -c below) is imported in place of the standard library and decides
# the verdict, while base_red_excuse.py trusts the verdict of a change that leaves this check's files alone. The
# reader imports only the standard library.
read_pin=(read "$manifest")
[[ -f "$pin_file" ]] && read_pin=(read-pin-file "$pin_file" "$manifest")
if ! pinned="$(python3 -I "$pin_reader" "${read_pin[@]}" 2>&1)"; then
  echo "error: no canonical cmux-app-ffi pin in $manifest: ${pinned#error: }" >&2
  exit 1
fi
read -r sha checksum <<<"$pinned"
url="https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-$sha/$asset"

cd "$root"
if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
  # A fleet ci-step checkout has no `origin` remote (step 6e04059b590e). Only
  # a shallow checkout fetches shallow: a worktree of a full warm checkout
  # must not turn its repository shallow.
  remote=origin
  git remote get-url origin >/dev/null 2>&1 || remote="${CMUX_APP_FFI_PIN_REMOTE:-https://github.com/manaflow-ai/cmux.git}"
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$sha" \
    || { echo "error: pinned source sha $sha is not available from $remote" >&2; exit 1; }
fi
# What the crates inherit of the workspace manifest at REV: the manifest and the crates' Cargo.toml files at REV (the
# crate list of HEAD; a crate whose own Cargo.toml changed is a changed input anyway).
workspace_view() { # workspace_view REV
  local dir crate index=0 status=0
  local manifests=()
  dir="$(mktemp -d)"
  git show "$1:$workspace_manifest" >"$dir/workspace.toml" 2>/dev/null || : >"$dir/workspace.toml"
  for crate in "${crates[@]}"; do
    git show "$1:$crate/Cargo.toml" >"$dir/$index.toml" 2>/dev/null || : >"$dir/$index.toml"
    manifests+=("$dir/$index.toml")
    index=$((index + 1))
  done
  python3 -I "$pin_reader" workspace-view "$dir/workspace.toml" "${manifests[@]}" || status=$?
  rm -rf "$dir"
  return "$status"
}
views_differ() { # views_differ A B: exit 0 when what the crates inherit of the workspace manifest differs
  [[ "$narrowed" -eq 1 ]] || return 1
  local a b
  if ! a="$(workspace_view "$1")" || ! b="$(workspace_view "$2")"; then
    echo "error: the app FFI inputs cannot be listed: what the FFI crates inherit of $workspace_manifest cannot be read (above)" >&2
    exit 1
  fi
  [[ "$a" != "$b" ]]
}
inputs_differ() { # inputs_differ A B: exit 0 when an input differs between commits A and B
  ! git diff --quiet "$1" "$2" -- "${paths[@]}" || views_differ "$1" "$2"
}
own_change=1
if [[ -n "$base_ref" ]]; then
  if base_commit="$(git rev-parse --verify --quiet "$base_ref^{commit}")"; then
    # The base's pin through the same canonical match, in either form; a base that does not match it pins nothing
    # here.
    base_dir="$(mktemp -d)"
    base_pin=""
    if git show "$base_commit:Packages/macOS/CmuxNext/Package.swift" >"$base_dir/Package.swift" 2>/dev/null; then
      read_pin=(read "$base_dir/Package.swift")
      git show "$base_commit:Packages/macOS/CmuxNext/app-ffi-pin.json" >"$base_dir/app-ffi-pin.json" 2>/dev/null \
        && read_pin=(read-pin-file "$base_dir/app-ffi-pin.json" "$base_dir/Package.swift")
      base_pin="$(python3 -I "$pin_reader" "${read_pin[@]}" 2>/dev/null | awk '{print $1}' || true)"
    fi
    rm -rf "$base_dir"
    if ! inputs_differ "$base_commit" HEAD && [[ "$base_pin" == "$sha" ]]; then
      own_change=0
    fi
  else
    echo "warning: --base $base_ref is not a commit here; checking against the pin only" >&2
  fi
fi
drift=0
shown=("${paths[@]}")
git diff --quiet "$sha" HEAD -- "${paths[@]}" || drift=1
# The report names the workspace manifest when what the crates inherit of it changed.
if views_differ "$sha" HEAD; then
  drift=1
  shown+=("$workspace_manifest")
fi
if [[ "$drift" -eq 1 && "$own_change" -eq 0 ]]; then
  echo "note: base drift: the app FFI sources on $base_ref differ from the pinned source $sha, and this change touches neither; the base's push run reports it to the owning lane"
  git diff --stat "$sha" HEAD -- "${shown[@]}" || true
elif [[ "$drift" -eq 1 ]]; then
  echo "error: the app FFI sources changed since the pinned source $sha:" >&2
  git diff --stat "$sha" HEAD -- "${shown[@]}" >&2
  [[ ${#shown[@]} -gt ${#paths[@]} ]] \
    && echo "  ($workspace_manifest: a key, dependency entry or lint table the FFI crates inherit changed)" >&2
  # Who owns the drift: the lane of each changed crate, and the commits.
  owners=""
  for path in $(git diff --name-only "$sha" HEAD -- "${shown[@]}"); do
    case "$path" in
      cmux-tui/crates/cmux-rd-*) owners+=$'\n  remote desktop lane (cmux-rd-core/proto/ffi)' ;;
      cmux-tui/crates/cmux-layout-reducer*) owners+=$'\n  sidebar lane (cmux-layout-reducer, -ffi)' ;;
      cmux-tui/crates/cmux-remote-browser/*) owners+=$'\n  remote browser lane (cmux-remote-browser)' ;;
      cmux-tui/crates/cmux-palette-ranker/*) owners+=$'\n  palette lane (cmux-palette-ranker, cx-6loo3)' ;;
      *) owners+=$'\n  app FFI packaging (test triage lane: cmux-app-ffi, build-app-ffi.sh, toolchain)' ;;
    esac
  done
  echo "Owning lane(s), which publish the release and update the pin:$(sort -u <<<"$owners")" >&2
  echo "Commits since the pin:" >&2
  git log --format='  %h %an: %s' "$sha..HEAD" -- "${shown[@]}" >&2 || true
  echo "Fix: the push to feat-cmux-next runs app-ffi-release.yml; publish its artifact (by hand when the run says so), then pin the new URL and checksum in Package.swift in one commit, in the same push as the source change when possible." >&2
  exit 1
else
  echo "app FFI pin: sources match $sha"
fi

if [[ "$verify" -eq 1 ]]; then
  base="${url%/"$asset"}"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  # Every error retries (a runner's TLS read timeout is curl 35, which plain
  # --retry treats as fatal: cmux-next.yml run 37317248488).
  get() { curl -fsSL --connect-timeout 15 --max-time 60 --retry 5 --retry-all-errors --retry-delay 3 "$@"; }
  # A release download that still fails goes through the release-assets API, which serves the same file another
  # way (2026-11-08: every release download answered 504 for hours while the API served the same bytes). What it
  # gets is checked below like the download.
  fetch() {
    get -o "$1" "$2" && return
    [[ "$2" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$ ]] || return 1
    local api="https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}" name="${BASH_REMATCH[4]}" asset_url
    echo "app FFI pin: $2 failed; fetching it through the release-assets API" >&2
    asset_url="$(get -H 'Accept: application/vnd.github+json' "$api/releases/tags/${BASH_REMATCH[3]}" \
      | python3 -I -c 'import json, sys; print(next(a["url"] for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]))' "$name")" \
      || return 1
    get -H 'Accept: application/octet-stream' -o "$1" "$asset_url"
  }
  fetch "$work/SOURCE_SHA" "$base/SOURCE_SHA"
  fetch "$work/SHA256SUMS" "$base/SHA256SUMS"
  [[ "$(tr -d '[:space:]' < "$work/SOURCE_SHA")" == "$sha" ]] \
    || { echo "error: release SOURCE_SHA $(cat "$work/SOURCE_SHA") is not the pinned sha $sha" >&2; exit 1; }
  grep -qxF "$checksum  $asset" "$work/SHA256SUMS" \
    || { echo "error: release SHA256SUMS does not carry the pinned checksum $checksum" >&2; exit 1; }
  echo "app FFI pin: release built from $sha with checksum $checksum"
fi
