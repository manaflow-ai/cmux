#!/usr/bin/env bash
# Checks the cmux-mobile-ffi pin (the iOS app's Rust core: CmuxMobileFFIFFI.xcframework
# and its uniffi Swift bindings) in Packages/Shared/CmuxMobileFFI, the package
# ios/CmuxiOS links. The mobile counterpart of check-app-ffi-pin.sh.
#
#   scripts/cmux-next/check-mobile-ffi-pin.sh [--verify-release] [--tree DIR] [--stale-grace SECONDS]
#   scripts/cmux-next/check-mobile-ffi-pin.sh --list-inputs [--tree DIR]
#
# - mobile-ffi-pin.json is in its one format (scripts/cmux-next/mobile_ffi_pin.py).
#   Both fields empty means unpinned (no release yet): that passes with a note, and
#   then Sources/CmuxMobileFFI/CmuxMobileFFI.swift must not exist.
# - Pinned: the bindings exist, and the FFI sources at HEAD (cmux-mobile-ffi and
#   every crate it reaches through Cargo path dependencies, plus the toolchain)
#   equal those of the pinned source sha (the tag is cmux-mobile-ffi-<sha>). A pull
#   request cannot pin its own FFI change: cmux-mobile-ffi.yml publishes a release
#   only from a feat-cmux-next push, and its repin job pins it.
# - --stale-grace SECONDS, for the feat-cmux-next push run: a pin behind the
#   sources passes with a note while the first commit that left it behind is
#   younger than SECONDS, and fails once it is older.
# - --verify-release: downloads the release's SOURCE_SHA and SHA256SUMS anonymously
#   and fails unless they name the pinned sha, the pinned checksum and the digest of
#   the committed bindings.
set -euo pipefail

verify=0
list_inputs=0
tree=""
stale_grace=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-release) verify=1 ;;
    --list-inputs) list_inputs=1 ;;
    --tree) tree="${2:?--tree needs a directory}"; shift ;;
    --stale-grace)
      stale_grace="${2:?--stale-grace needs seconds}"; shift
      [[ "$stale_grace" =~ ^[0-9]+$ ]] || { echo "error: --stale-grace needs a whole number of seconds" >&2; exit 2; } ;;
    *) echo "usage: $0 [--verify-release] [--list-inputs] [--tree DIR] [--stale-grace SECONDS]" >&2; exit 2 ;;
  esac
  shift
done

code="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
root="$code"
if [[ -n "$tree" ]]; then
  root="$(cd "$tree" 2>/dev/null && pwd -P)" || { echo "error: --tree $tree is not a directory" >&2; exit 2; }
fi
package="$root/Packages/Shared/CmuxMobileFFI"
pin_file="$package/mobile-ffi-pin.json"
bindings="$package/Sources/CmuxMobileFFI/CmuxMobileFFI.swift"
asset="CmuxMobileFFIFFI.xcframework.zip"

# The FFI sources: cmux-mobile-ffi and every crate it reaches through Cargo path
# dependencies or path workspace dependencies (check-app-ffi-pin.sh's walk), less
# [dev-dependencies], which never reach the library (cmux-mobile-ffi's tests pull
# cmux-conversation). cmux-mobile-ffi.yml's push paths must cover every input
# (tests/test_mobile_ffi_pin.py), or a change to one would never be published.
# A manifest without its dev-dependency sections.
built_manifest() {
  awk '/^[[:space:]]*\[/ { dev = ($0 ~ /dev-dependencies/) } !dev' "$1"
}
ffi_crates() {
  local queue=" cmux-tui/crates/cmux-mobile-ffi " seen=" " dir dep resolved workspace_paths=""
  [[ -f "$root/cmux-tui/Cargo.toml" ]] && workspace_paths="$(sed -nE \
    's/^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*\{[^}]*path[[:space:]]*=[[:space:]]*"([^"]+)".*/\1 cmux-tui\/\2/p' \
    "$root/cmux-tui/Cargo.toml")"
  while [[ -n "${queue// /}" ]]; do
    dir="$(awk '{print $1}' <<<"$queue")"
    queue=" ${queue#*" $dir "} "
    [[ "$seen" == *" $dir "* || ! -f "$root/$dir/Cargo.toml" ]] && continue
    seen+="$dir "
    while IFS= read -r dep; do
      resolved="$(cd "$root/$dir/$dep" 2>/dev/null && pwd -P)" || continue
      [[ -f "$resolved/Cargo.toml" && "$resolved" == "$root"/* ]] || continue
      queue+="${resolved#"$root"/} "
    done < <(built_manifest "$root/$dir/Cargo.toml" | grep -oE 'path[[:space:]]*=[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')
    while IFS= read -r dep; do
      resolved="$(awk -v name="$dep" '$1 == name { sub(/\/$/, "", $2); print $2; exit }' <<<"$workspace_paths")"
      [[ -n "$resolved" ]] && queue+="$resolved "
    done < <(grep -oE '^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*(\.workspace[[:space:]]*=[[:space:]]*true|=[[:space:]]*\{[^}]*workspace[[:space:]]*=[[:space:]]*true)' <(built_manifest "$root/$dir/Cargo.toml") \
      | sed -E 's/^[[:space:]]*([A-Za-z0-9_-]+).*/\1/')
  done
  tr ' ' '\n' <<<"$seen" | sed '/^$/d' | sort
}
paths=()
while IFS= read -r crate; do paths+=("$crate"); done < <(ffi_crates)
paths+=(cmux-tui/rust-toolchain.toml)
if [[ "$list_inputs" -eq 1 ]]; then
  printf '%s\n' "${paths[@]}"
  exit 0
fi
# Each crate's tests/, benches/ and examples/ never reach the library (app_ffi_pin.py not-built, one definition).
specs=("${paths[@]}")
while IFS= read -r dir; do
  [[ -n "$dir" ]] && specs+=(":(exclude,literal)$dir")
done < <(python3 -I "$code/scripts/ci/app_ffi_pin.py" not-built "$root" "${paths[@]}")

if ! pinned="$(python3 -I "$code/scripts/cmux-next/mobile_ffi_pin.py" read "$pin_file" 2>&1)"; then
  echo "error: no canonical cmux-mobile-ffi pin in $pin_file: ${pinned#error: }" >&2
  exit 1
fi
if [[ "$pinned" == unpinned ]]; then
  if [[ -e "$bindings" ]]; then
    echo "error: $pin_file is unpinned but $bindings exists; the bindings only come with a pin (repin-mobile-ffi.sh)" >&2
    exit 1
  fi
  echo "note: cmux-mobile-ffi is not pinned yet: cmux-mobile-ffi.yml publishes the first release from a feat-cmux-next push and its repin job pins it"
  exit 0
fi
read -r sha checksum <<<"$pinned"
[[ -f "$bindings" ]] || { echo "error: $pin_file pins cmux-mobile-ffi-$sha but $bindings is missing (repin-mobile-ffi.sh writes both)" >&2; exit 1; }

cd "$root"
remote=origin
git remote get-url origin >/dev/null 2>&1 || remote="${CMUX_MOBILE_FFI_PIN_REMOTE:-https://github.com/manaflow-ai/cmux.git}"
if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$sha" \
    || { echo "error: pinned source sha $sha is not available from $remote" >&2; exit 1; }
fi
behind_since() {
  local first
  for _ in 1 2 3 4 5 6 7 8; do
    git merge-base --is-ancestor "$sha" HEAD 2>/dev/null && break
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] || return 1
    git fetch --quiet --deepen=50 "$remote" "$(git rev-parse HEAD)" 2>/dev/null || return 1
  done
  git merge-base --is-ancestor "$sha" HEAD 2>/dev/null || return 1
  first="$(git log --reverse --format=%ct "$sha..HEAD" -- "${specs[@]}")" || return 1
  first="${first%%$'\n'*}"
  [[ "$first" =~ ^[0-9]+$ ]] || return 1
  echo "$first"
}
if git diff --quiet "$sha" HEAD -- "${specs[@]}"; then
  echo "mobile FFI pin: sources match $sha"
else
  verdict="error: the cmux-mobile-ffi sources changed since the pinned source $sha"
  if [[ "$stale_grace" -gt 0 ]]; then
    now="${CMUX_MOBILE_FFI_PIN_NOW:-$(date +%s)}"
    if since="$(behind_since)"; then
      age=$(( now - since ))
      if (( age < stale_grace )); then
        verdict="note: the pin is behind: the cmux-mobile-ffi sources changed $(( age / 60 )) min ago and the pinned source is still $sha; cmux-mobile-ffi.yml publishes that push's release and pins it, and this check fails once the pin is still behind after $(( stale_grace / 60 )) min"
      else
        verdict="error: the pin has been behind for $(( age / 60 )) min, longer than the $(( stale_grace / 60 )) min a release and its pin may take: look at the cmux-mobile-ffi runs of the commits below"
      fi
    else
      verdict="error: when the pin fell behind could not be read from this checkout's history, so it is judged as stale"
    fi
  fi
  if [[ "$verdict" == note:* ]]; then
    echo "$verdict"
    git log --format='  %h %an: %s' "$sha..HEAD" -- "${specs[@]}" || true
  else
    echo "$verdict" >&2
    git diff --stat "$sha" HEAD -- "${specs[@]}" >&2 || true
    echo "Commits since the pin:" >&2
    git log --format='  %h %an: %s' "$sha..HEAD" -- "${specs[@]}" >&2 || true
    echo "Fix: the feat-cmux-next push runs cmux-mobile-ffi.yml, whose publish and repin jobs pin the new release; when they cannot, run its HAND_PUBLISH line, then scripts/cmux-next/repin-mobile-ffi.sh SHA CHECKSUM and commit Packages/Shared/CmuxMobileFFI." >&2
    echo "A pull request that changes the FFI and its Swift callers: land the Rust change first, then the Swift change after the re-pin." >&2
    exit 1
  fi
fi

if [[ "$verify" -eq 1 ]]; then
  base="${CMUX_MOBILE_FFI_RELEASE_BASE:-https://github.com/manaflow-ai/cmux/releases/download}/cmux-mobile-ffi-$sha"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  get() { curl -fsSL --connect-timeout 15 --max-time 60 --retry 5 --retry-all-errors --retry-delay 3 "$@"; }
  get -o "$work/SOURCE_SHA" "$base/SOURCE_SHA"
  get -o "$work/SHA256SUMS" "$base/SHA256SUMS"
  [[ "$(tr -d '[:space:]' < "$work/SOURCE_SHA")" == "$sha" ]] \
    || { echo "error: release SOURCE_SHA $(cat "$work/SOURCE_SHA") is not the pinned sha $sha" >&2; exit 1; }
  grep -qxF "$checksum  $asset" "$work/SHA256SUMS" \
    || { echo "error: release SHA256SUMS does not carry the pinned checksum $checksum" >&2; exit 1; }
  digest="$(shasum -a 256 "$bindings" | awk '{print $1}')"
  grep -qxF "$digest  CmuxMobileFFI.swift" "$work/SHA256SUMS" \
    || { echo "error: the committed $bindings ($digest) are not the release's bindings" >&2; exit 1; }
  echo "mobile FFI pin: release built from $sha with checksum $checksum and the committed bindings"
fi
