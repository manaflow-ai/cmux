#!/usr/bin/env bash
# Pin or fetch the hosted macOS arm64 cmux-tui that the cmux-next app bundles.
#
# The pin (scripts/cmux-next/cmux-tui.pin) names one commit, the public
# commit-addressed binary the `cmux-tui artifacts` workflow published for it
# (url=https://files.cmux.com/cmux-tui/<commit>/cmux-tui-aarch64-apple-darwin),
# the workflow run that built it (run=), the cmux-tui.yml run that verified the
# cmux-next daemon tests on that commit (verified_run=), and the binary's
# sha256. The Xcode "Bundle cmux-tui" phase (bundle-cmux-tui.sh) bundles
# cmux-tui/target/hosted/<commit>/cmux-tui when its sha256 matches.
#
# `fetch` needs no GitHub credentials: it downloads the public url with curl
# and refuses any byte that does not match the pinned sha256, so the fleet's
# workers (no gh, no token) and a fresh checkout fetch the same binary.
# scripts/reload.sh runs it before building cmux-next.
#
# Refresh the pin after a daemon change lands on feat-cmux-next:
#   1. ./scripts/verify-cmux-tui-hosted.sh --filter cmux_next_ on the pushed
#      commit (records the verification run).
#   2. Publish that exact commit's binaries (branch dogfood publish):
#        git push origin <sha>:refs/heads/cmux-tui-pin-<short>
#        gh workflow run cmux-tui-artifacts.yml --repo manaflow-ai/cmux --ref cmux-tui-pin-<short>
#   3. ./scripts/cmux-next/pin-cmux-tui.sh pin --commit <sha> --verified-run <run-id>
#   4. Commit scripts/cmux-next/cmux-tui.pin; delete the helper branch.
#
# Usage: pin-cmux-tui.sh pin --commit <sha> [--verified-run <id>] | fetch | show | path
set -euo pipefail

TARGET="aarch64-apple-darwin"
BASE="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
pin_file="$script_dir/cmux-tui.pin"

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
pin_field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/, ""); print; exit}' "$pin_file"; }

read_pin() {
  [[ -f "$pin_file" ]] || { echo "error: no pin at $pin_file" >&2; exit 1; }
  pin_commit="$(pin_field commit)"
  pin_run="$(pin_field run)"
  pin_url="$(pin_field url)"
  pin_sha256="$(pin_field sha256)"
  [[ "$pin_commit" =~ ^[0-9a-f]{40}$ && "$pin_sha256" =~ ^[0-9a-f]{64}$ && "$pin_url" == https://* ]] || {
    echo "error: malformed pin $pin_file (needs commit=, url=https://..., sha256=)" >&2; exit 1; }
}

# Downloads $1 to $2 with retries; never follows to a non-HTTPS URL.
download() {
  curl -fsSL --proto '=https' --retry 4 --retry-delay 2 --connect-timeout 20 --max-time 600 -o "$2" "$1"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  pin)
    commit=""
    verified_run=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --commit) commit="${2:?}"; shift 2 ;;
        --verified-run) verified_run="${2:?}"; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: pin needs --commit <40-hex sha>" >&2; exit 2; }
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-pin.XXXXXX")"
    trap 'rm -rf "$temp_dir"' EXIT
    manifest_url="$BASE/$commit/manifest.json"
    download "$manifest_url" "$temp_dir/manifest.json" || {
      echo "error: $manifest_url is not published; run the cmux-tui artifacts workflow on $commit (see --help)" >&2; exit 1; }
    read -r manifest_commit sha256 run < <(python3 - "$temp_dir/manifest.json" "cmux-tui-$TARGET" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
run = re.search(r"/actions/runs/(\d+)", m.get("attestationUrl") or "")
print(m.get("sourceCommit", ""), m.get("binaries", {}).get(sys.argv[2], ""), run.group(1) if run else "")
PY
)
    [[ "$manifest_commit" == "$commit" && "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo "error: $manifest_url does not describe cmux-tui-$TARGET for $commit" >&2; exit 1; }
    url="$BASE/$commit/cmux-tui-$TARGET"
    download "$url" "$temp_dir/cmux-tui"
    [[ "$(sha256_of "$temp_dir/cmux-tui")" == "$sha256" ]] || { echo "error: $url does not match its manifest" >&2; exit 1; }
    chmod 755 "$temp_dir/cmux-tui"
    version="$("$temp_dir/cmux-tui" --version 2>/dev/null | head -n 1 || true)"
    [[ "$version" == *"${commit:0:7}"* ]] || { echo "error: $url reports '$version', not commit $commit" >&2; exit 1; }
    {
      echo "# Hosted cmux-tui the cmux-next app bundles. Refresh: scripts/cmux-next/pin-cmux-tui.sh --help"
      echo "commit=$commit"
      echo "url=$url"
      echo "run=$run"
      [[ -n "$verified_run" ]] && echo "verified_run=$verified_run"
      echo "sha256=$sha256"
    } > "$pin_file"
    echo "pinned $commit ($version)"
    cat "$pin_file"
    ;;
  fetch)
    read_pin
    dir="$repo_root/cmux-tui/target/hosted/$pin_commit"
    binary="$dir/cmux-tui"
    if [[ -f "$binary" && "$(sha256_of "$binary")" == "$pin_sha256" ]]; then
      echo "pinned cmux-tui ${pin_commit:0:12} already present: $binary"
      exit 0
    fi
    mkdir -p "$dir"
    temp="$(mktemp "$dir/.cmux-tui.XXXXXX")"
    trap 'rm -f "$temp"' EXIT
    if ! download "$pin_url" "$temp"; then
      echo "error: could not download the pinned cmux-tui from $pin_url" >&2
      exit 1
    fi
    actual="$(sha256_of "$temp")"
    if [[ "$actual" != "$pin_sha256" ]]; then
      echo "error: $pin_url has sha256 $actual, but $pin_file pins $pin_sha256" >&2
      exit 1
    fi
    chmod 755 "$temp"
    # Rename into place: a rewritten Mach-O keeps a stale code signature.
    mv -f "$temp" "$binary"
    echo "fetched pinned cmux-tui ${pin_commit:0:12} to $binary"
    ;;
  show)
    read_pin
    echo "commit=$pin_commit run=$pin_run sha256=$pin_sha256 url=$pin_url"
    ;;
  path)
    read_pin
    echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-tui"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
