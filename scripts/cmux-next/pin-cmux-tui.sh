#!/usr/bin/env bash
# Pin or fetch the hosted macOS arm64 cmux-tui that the cmux-next app bundles.
#
# The pin (scripts/cmux-next/cmux-tui.pin) names one commit, the cmux-tui.yml
# workflow run that verified it, and the binary's sha256. The Xcode "Bundle
# cmux-tui" phase (bundle-cmux-tui.sh) prefers that binary at
# cmux-tui/target/hosted/<commit>/cmux-tui over the user-cache release client,
# because the release client lacks the cmux-next daemon capabilities.
#
# Refresh the pin after a daemon change lands on the branch:
#   1. On a clean checkout of the pushed branch head:
#        ./scripts/verify-cmux-tui-hosted.sh --filter cmux_next_
#      (downloads cmux-tui/target/hosted/<HEAD>/cmux-tui on success)
#   2. ./scripts/cmux-next/pin-cmux-tui.sh pin [--commit <sha>] [--run <run-id>]
#   3. Commit scripts/cmux-next/cmux-tui.pin.
#
# Another checkout gets the pinned binary with:
#   ./scripts/cmux-next/pin-cmux-tui.sh fetch
# GitHub keeps workflow artifacts for a limited time; when fetch reports the
# artifact expired, refresh the pin.
set -euo pipefail

REPO="manaflow-ai/cmux"
WORKFLOW="cmux-tui.yml"
ARTIFACT="cmux-tui-aarch64-apple-darwin"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
pin_file="$script_dir/cmux-tui.pin"

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
  echo "Usage: $0 pin [--commit <sha>] [--run <run-id>] | fetch | show"
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

read_pin() {
  [[ -f "$pin_file" ]] || { echo "error: no pin at $pin_file" >&2; exit 1; }
  pin_commit="$(awk -F= '$1=="commit"{print $2}' "$pin_file")"
  pin_run="$(awk -F= '$1=="run"{print $2}' "$pin_file")"
  pin_sha256="$(awk -F= '$1=="sha256"{print $2}' "$pin_file")"
  [[ "$pin_commit" =~ ^[0-9a-f]{40}$ && "$pin_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "error: malformed pin $pin_file" >&2; exit 1; }
}

cmd="${1:-}"
shift || true
case "$cmd" in
  pin)
    commit=""
    run=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --commit) commit="$2"; shift 2 ;;
        --run) run="$2"; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [[ -n "$commit" ]] || commit="$(git -C "$repo_root" rev-parse HEAD)"
    binary="$repo_root/cmux-tui/target/hosted/$commit/cmux-tui"
    if [[ ! -x "$binary" ]]; then
      echo "error: $binary is missing; run ./scripts/verify-cmux-tui-hosted.sh --filter cmux_next_ on $commit first" >&2
      exit 1
    fi
    if [[ -z "$run" ]]; then
      run="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --commit "$commit" --status success \
        --limit 20 --json databaseId,displayTitle \
        --jq "[.[] | select(.displayTitle | contains(\"$commit\"))][0].databaseId")"
    fi
    [[ "$run" =~ ^[0-9]+$ ]] || { echo "error: no successful $WORKFLOW run found for $commit; pass --run" >&2; exit 1; }
    version="$("$binary" --version 2>/dev/null | head -n 1 || true)"
    if [[ "$version" != *"$commit"* ]]; then
      echo "error: $binary reports '$version', not commit $commit" >&2
      exit 1
    fi
    {
      echo "# Hosted cmux-tui the cmux-next app bundles. Refresh: scripts/cmux-next/pin-cmux-tui.sh"
      echo "commit=$commit"
      echo "run=$run"
      echo "sha256=$(sha256_of "$binary")"
    } > "$pin_file"
    echo "pinned $commit (run https://github.com/$REPO/actions/runs/$run)"
    cat "$pin_file"
    ;;
  fetch)
    read_pin
    dir="$repo_root/cmux-tui/target/hosted/$pin_commit"
    binary="$dir/cmux-tui"
    if [[ -f "$binary" && "$(sha256_of "$binary")" == "$pin_sha256" ]]; then
      echo "already present: $binary"
      exit 0
    fi
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-pin.XXXXXX")"
    trap 'rm -rf "$temp_dir"' EXIT
    if ! gh run download --repo "$REPO" "$pin_run" --name "$ARTIFACT" --dir "$temp_dir"; then
      echo "error: could not download $ARTIFACT from run $pin_run (expired?); refresh the pin" >&2
      exit 1
    fi
    downloaded="$(find "$temp_dir" -type f -name "$ARTIFACT" -print | sed -n '1p')"
    [[ -n "$downloaded" ]] || { echo "error: run $pin_run has no $ARTIFACT binary" >&2; exit 1; }
    actual="$(sha256_of "$downloaded")"
    if [[ "$actual" != "$pin_sha256" ]]; then
      echo "error: downloaded sha256 $actual does not match pin $pin_sha256" >&2
      exit 1
    fi
    mkdir -p "$dir"
    rm -f "$binary"
    install -m 0755 "$downloaded" "$binary"
    echo "fetched $binary"
    ;;
  show)
    read_pin
    echo "commit=$pin_commit run=$pin_run sha256=$pin_sha256"
    ;;
  -h|--help|"") usage; [[ -n "$cmd" ]] || exit 2 ;;
  *) usage >&2; exit 2 ;;
esac
