#!/usr/bin/env bash
# Checks the app FFI pin (CCmuxAppFFI: the remote desktop core and the sidebar
# layout reducer over one Rust runtime) in Packages/macOS/CmuxNext/Package.swift.
#
#   scripts/cmux-next/check-app-ffi-pin.sh [--verify-release | --list-inputs]
#
# Fails when the FFI sources at HEAD differ from the pinned source sha (the tag
# is cmux-app-ffi-<source sha>): change the Rust code, let
# .github/workflows/app-ffi-release.yml publish the new release, then pin its
# URL and checksum in one commit. With --verify-release it also downloads the
# release's SOURCE_SHA and SHA256SUMS anonymously and fails unless they name
# the pinned sha and the pinned checksum.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
manifest="$root/Packages/macOS/CmuxNext/Package.swift"
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
paths+=(cmux-tui/rust-toolchain.toml scripts/cmux-next/build-app-ffi.sh)
# --list-inputs prints them (tests/app-ffi-release-paths.test.sh keeps the
# release workflow's push paths in step with this list).
if [[ "${1:-}" == "--list-inputs" ]]; then
  printf '%s\n' "${paths[@]}"
  exit 0
fi

url="$(grep -oE "https://github\.com/[^\"]+/releases/download/cmux-app-ffi-[0-9a-f]{40}/${asset//./\\.}" "$manifest" | head -n 1)"
checksum="$(grep -A3 'name: "CCmuxAppFFI"' "$manifest" | grep -oE 'checksum: "[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}' | head -n 1)"
if [[ -z "$url" || -z "$checksum" ]]; then
  echo "error: no cmux-app-ffi pin (url with a 40-character sha and a 64-character checksum) in $manifest" >&2
  exit 1
fi
sha="$(grep -oE 'cmux-app-ffi-[0-9a-f]{40}' <<<"$url" | sed 's/cmux-app-ffi-//')"

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
if ! git diff --quiet "$sha" HEAD -- "${paths[@]}"; then
  echo "error: the app FFI sources changed since the pinned source $sha:" >&2
  git diff --stat "$sha" HEAD -- "${paths[@]}" >&2
  # Who owns the drift: the lane of each changed crate, and the commits.
  owners=""
  for path in $(git diff --name-only "$sha" HEAD -- "${paths[@]}"); do
    case "$path" in
      cmux-tui/crates/cmux-rd-*) owners+=$'\n  remote desktop lane (cmux-rd-core/proto/ffi)' ;;
      cmux-tui/crates/cmux-layout-reducer*) owners+=$'\n  sidebar lane (cmux-layout-reducer, -ffi)' ;;
      cmux-tui/crates/cmux-remote-browser/*) owners+=$'\n  remote browser lane (cmux-remote-browser)' ;;
      *) owners+=$'\n  app FFI packaging (test triage lane: cmux-app-ffi, build-app-ffi.sh, toolchain)' ;;
    esac
  done
  echo "Owning lane(s), which publish the release and update the pin:$(sort -u <<<"$owners")" >&2
  echo "Commits since the pin:" >&2
  git log --format='  %h %an: %s' "$sha..HEAD" -- "${paths[@]}" >&2 || true
  echo "Fix: the push to feat-cmux-next runs app-ffi-release.yml; publish its artifact (by hand when the run says so), then pin the new URL and checksum in Package.swift in one commit, in the same push as the source change when possible." >&2
  exit 1
fi
echo "app FFI pin: sources match $sha"

if [[ "${1:-}" == "--verify-release" ]]; then
  base="${url%/"$asset"}"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  # Every error retries (a runner's TLS read timeout is curl 35, which plain
  # --retry treats as fatal: cmux-next.yml run 37317248488).
  fetch() { curl -fsSL --connect-timeout 15 --max-time 60 --retry 5 --retry-all-errors --retry-delay 3 -o "$1" "$2"; }
  fetch "$work/SOURCE_SHA" "$base/SOURCE_SHA"
  fetch "$work/SHA256SUMS" "$base/SHA256SUMS"
  [[ "$(tr -d '[:space:]' < "$work/SOURCE_SHA")" == "$sha" ]] \
    || { echo "error: release SOURCE_SHA $(cat "$work/SOURCE_SHA") is not the pinned sha $sha" >&2; exit 1; }
  grep -qxF "$checksum  $asset" "$work/SHA256SUMS" \
    || { echo "error: release SHA256SUMS does not carry the pinned checksum $checksum" >&2; exit 1; }
  echo "app FFI pin: release built from $sha with checksum $checksum"
fi
