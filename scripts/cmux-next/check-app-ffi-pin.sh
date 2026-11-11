#!/usr/bin/env bash
# Checks the app FFI pin (CCmuxAppFFI: the remote desktop core and the sidebar
# layout reducer over one Rust runtime) in Packages/macOS/CmuxNext/Package.swift.
#
#   scripts/cmux-next/check-app-ffi-pin.sh [--verify-release] [--base REF] [--tree DIR] [--stale-grace SECONDS]
#   scripts/cmux-next/check-app-ffi-pin.sh --list-inputs [--tree DIR]
#
# Fails when the FFI sources at HEAD differ from the pinned source sha (the tag
# is cmux-app-ffi-<source sha>): change the Rust code, let
# .github/workflows/app-ffi-release.yml publish the new release, then pin its
# URL and checksum in one commit. With --verify-release it also downloads the
# release's SOURCE_SHA and SHA256SUMS anonymously and fails unless they name
# the pinned sha and the pinned checksum.
#
# --stale-grace SECONDS is for the push run of feat-cmux-next, where a pin
# behind the sources is the normal state after every FFI commit: its release
# can only be built from that pushed commit, so no pin could match it yet.
# app-ffi-release.yml publishes the release and pins it within the hour. With
# the flag, a pin behind the sources passes with a note while the first commit
# that left it behind is younger than SECONDS, and fails once it is older:
# then the release or the re-pin did not happen and somebody has to look.
# Every FFI commit was a red tip for 30 to 240 minutes before (2026-11-11:
# cmux-next runs 42952459700, 42958342526, 42960857925, 42973010316). The
# release's checksum is still verified, and a pull request never passes it
# (cmux-next.yml gives the flag on pushes only).
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
stale_grace=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-release) verify=1 ;;
    --base) base_ref="${2:?--base needs a ref}"; shift ;;
    --list-inputs) list_inputs=1 ;;
    --tree) tree="${2:?--tree needs a directory}"; shift ;;
    --stale-grace)
      stale_grace="${2:?--stale-grace needs seconds}"; shift
      [[ "$stale_grace" =~ ^[0-9]+$ ]] || { echo "error: --stale-grace needs a whole number of seconds" >&2; exit 2; } ;;
    *) echo "usage: $0 [--verify-release] [--base REF] [--tree DIR] [--stale-grace SECONDS]" >&2; exit 2 ;;
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

# The FFI sources: cmux-app-ffi and every crate it reaches through Cargo path
# dependencies (cmux-rd-ffi pulls cmux-remote-browser, which a hand list
# missed on 2026-10-07), then the toolchain and the build script. Derived
# from the Cargo.toml files at HEAD, so a new path dependency is never missed.
ffi_crates() {
  local queue=" cmux-tui/crates/cmux-app-ffi " seen=" " dir dep resolved
  while [[ -n "${queue// /}" ]]; do
    dir="$(awk '{print $1}' <<<"$queue")"
    queue=" ${queue#*" $dir "} "
    [[ "$seen" == *" $dir "* || ! -f "$root/$dir/Cargo.toml" ]] && continue
    seen+="$dir "
    while IFS= read -r dep; do
      # [lib] and [[bin]] paths name files; only a directory with a Cargo.toml is a crate.
      resolved="$(cd "$root/$dir/$dep" 2>/dev/null && pwd -P)" || continue
      [[ -f "$resolved/Cargo.toml" && "$resolved" == "$root"/* ]] || continue
      queue+="${resolved#"$root"/} "
    done < <(grep -oE 'path[[:space:]]*=[[:space:]]*"[^"]+"' "$root/$dir/Cargo.toml" | sed -E 's/.*"([^"]+)"$/\1/')
  done
  tr ' ' '\n' <<<"$seen" | sed '/^$/d' | sort
}
paths=()
while IFS= read -r crate; do paths+=("$crate"); done < <(ffi_crates)
# Not an input: plans/cmux-next/spec-proposals/visuals/design-tokens.json,
# which cmux-motion's build.rs reads for its token table. A theme edit there
# must not mark the pin stale; the app passes its own token values to the
# motion C ABI (cmux_motion_resolve), and scripts/cmux-next/motion-parity.py
# compares them with the spec's.
paths+=(cmux-tui/rust-toolchain.toml scripts/cmux-next/build-app-ffi.sh)
# --list-inputs prints them (tests/app-ffi-release-paths.test.sh keeps the
# release workflow's push paths in step with this list).
if [[ "$list_inputs" -eq 1 ]]; then
  printf '%s\n' "${paths[@]}"
  exit 0
fi

# The pin is read only through scripts/ci/app_ffi_pin.py's fail-closed canonical match (the classifier, the repin
# picker and the repin script read it the same way). A Package.swift whose pin is not the canonical block fails here,
# naming its first line that does not match.
pin_reader="$code/scripts/ci/app_ffi_pin.py"
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
# A fleet ci-step checkout has no `origin` remote (step 6e04059b590e).
remote=origin
git remote get-url origin >/dev/null 2>&1 || remote="${CMUX_APP_FFI_PIN_REMOTE:-https://github.com/manaflow-ai/cmux.git}"
if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
  # Only a shallow checkout fetches shallow: a worktree of a full warm checkout
  # must not turn its repository shallow.
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$sha" \
    || { echo "error: pinned source sha $sha is not available from $remote" >&2; exit 1; }
fi
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
    if git diff --quiet "$base_commit" HEAD -- "${paths[@]}" && [[ "$base_pin" == "$sha" ]]; then
      own_change=0
    fi
  else
    echo "warning: --base $base_ref is not a commit here; checking against the pin only" >&2
  fi
fi
# When the pin fell behind: the commit time of the first commit after the pinned source that changed an FFI input.
# A shallow checkout (actions/checkout) holds no commit between the two, so its history is deepened, 50 commits at
# a time and at most 400, until it reaches the pinned source. Nothing when that cannot be read: the caller then
# fails as it would without --stale-grace.
behind_since() {
  local first
  for _ in 1 2 3 4 5 6 7 8; do
    git merge-base --is-ancestor "$sha" HEAD 2>/dev/null && break
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] || return 1
    git fetch --quiet --deepen=50 "$remote" "$(git rev-parse HEAD)" 2>/dev/null || return 1
  done
  git merge-base --is-ancestor "$sha" HEAD 2>/dev/null || return 1
  first="$(git log --reverse --format=%ct "$sha..HEAD" -- "${paths[@]}" | head -n 1)"
  [[ "$first" =~ ^[0-9]+$ ]] || return 1
  echo "$first"
}
behind_note=""
if [[ "$stale_grace" -gt 0 && "$own_change" -eq 1 ]] && ! git diff --quiet "$sha" HEAD -- "${paths[@]}"; then
  # CMUX_APP_FFI_PIN_NOW: the clock, for the test.
  now="${CMUX_APP_FFI_PIN_NOW:-$(date +%s)}"
  if since="$(behind_since)"; then
    age=$(( now - since ))
    if (( age < stale_grace )); then
      behind_note="note: the pin is behind: the app FFI sources changed $(( age / 60 )) min ago and the pinned source is still $sha. app-ffi-release.yml publishes the release of that push and pins it; this check fails when the pin is still behind after $(( stale_grace / 60 )) min."
    else
      behind_note="error: the pin has been behind for $(( age / 60 )) min, longer than the $(( stale_grace / 60 )) min a release and its pin may take: look at the app FFI release runs of the commits below."
    fi
  else
    behind_note="error: when the pin fell behind could not be read from this checkout's history, so it is judged as stale."
  fi
fi
if [[ "$behind_note" == note:* ]]; then
  echo "$behind_note"
  git diff --stat "$sha" HEAD -- "${paths[@]}" || true
  echo "Commits since the pin:"
  git log --format='  %h %an: %s' "$sha..HEAD" -- "${paths[@]}" || true
elif ! git diff --quiet "$sha" HEAD -- "${paths[@]}" && [[ "$own_change" -eq 0 ]]; then
  echo "note: base drift: the app FFI sources on $base_ref differ from the pinned source $sha, and this change touches neither; the base's push run reports it to the owning lane"
  git diff --stat "$sha" HEAD -- "${paths[@]}" || true
elif ! git diff --quiet "$sha" HEAD -- "${paths[@]}"; then
  echo "error: the app FFI sources changed since the pinned source $sha:" >&2
  [[ -z "$behind_note" ]] || echo "$behind_note" >&2
  git diff --stat "$sha" HEAD -- "${paths[@]}" >&2
  # Who owns the drift: the lane of each changed crate, and the commits.
  owners=""
  for path in $(git diff --name-only "$sha" HEAD -- "${paths[@]}"); do
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
  git log --format='  %h %an: %s' "$sha..HEAD" -- "${paths[@]}" >&2 || true
  echo "Fix: the push to feat-cmux-next runs app-ffi-release.yml; publish its artifact (by hand when the run says so), then pin the new URL and checksum in Package.swift in one commit, in the same push as the source change when possible." >&2
  # A release is published only from a feat-cmux-next push, so a pull request cannot pin its own FFI sources.
  echo "If this PR changes FFI inputs: split it into a Rust-only step A and a Swift step B after the re-pin (docs/ci/app-ffi-release.md, \"A pull request that changes FFI inputs\")." >&2
  exit 1
else
  echo "app FFI pin: sources match $sha"
fi

if [[ "$verify" -eq 1 ]]; then
  # With a pin that is behind, this still proves the pinned release is the one its tag names.
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
