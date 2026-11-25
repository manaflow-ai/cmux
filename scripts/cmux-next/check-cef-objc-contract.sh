#!/usr/bin/env bash
# The Chromium ObjC contract (check-cef-objc-contract.py) against the pinned engine binary, as a cmux-ci step on a
# fleet Mac, so a CEF bump's binary review needs no CI Mac job and no hand-run Mac:
#   cmux-ci run --class light --os macos --script scripts/cmux-next/check-cef-objc-contract.sh --ref SHA \
#     [--arg --write --artifact scripts/cmux-next/chromium-objc-contract.json]
# It fetches the manifest's arm64 engine with ensure-cef.sh (sha256-checked), then runs the check with --framework
# (and --write when asked, which merges new candidates as `unreviewed`). Arguments: none or --write. macOS only.
set -euo pipefail

if [[ "$#" -gt 1 || ( "$#" == 1 && "$1" != "--write" ) ]]; then
  echo "check-cef-objc-contract.sh: arguments must be none or --write (got $# argument(s): $*)" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "check-cef-objc-contract.sh: the --framework check reads the engine with xcrun dyld_info and otool: macOS only" >&2
  exit 2
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
python=/usr/bin/python3
[[ -x "$python" ]] || python="$(command -v python3)"
cef_dir="$("$here/ensure-cef.sh")"
framework="$cef_dir/Chromium Embedded Framework.framework"
if [[ ! -d "$framework" ]]; then
  framework="$(find "$cef_dir" -maxdepth 4 -type d -name 'Chromium Embedded Framework.framework' -print -quit)"
fi
if [[ -z "$framework" || ! -d "$framework" ]]; then
  echo "check-cef-objc-contract.sh: no Chromium Embedded Framework.framework under $cef_dir" >&2
  exit 1
fi
echo "check-cef-objc-contract.sh: engine $cef_dir"
"$python" -I "$here/check-cef-objc-contract.py" --root "$root" --framework "$framework" "$@"
if [[ "${1:-}" == "--write" ]]; then
  git -C "$root" diff --exit-code -- scripts/cmux-next/chromium-objc-contract.json \
    && echo "check-cef-objc-contract.sh: --write changed nothing: no new or stale selector in this engine"
fi
