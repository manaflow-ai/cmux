#!/usr/bin/env bash
# Points the CCmuxAppFFI binary target at a published app FFI release.
#
#   scripts/cmux-next/repin-app-ffi.sh SOURCE_SHA CHECKSUM [Package.swift]
#
# Rewrites the target's release URL (tag cmux-app-ffi-SOURCE_SHA) and SwiftPM
# checksum, and nothing else. app-ffi-release.yml's repin job runs it after a
# publish; scripts/cmux-next/check-app-ffi-pin.sh reads the same two fields.
set -euo pipefail

sha="${1:-}"
checksum="${2:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="${3:-$root/Packages/macOS/CmuxNext/Package.swift}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: SOURCE_SHA must be a 40-character commit, got '$sha'" >&2; exit 2; }
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo "error: CHECKSUM must be 64 hex characters, got '$checksum'" >&2; exit 2; }

python3 - "$manifest" "$sha" "$checksum" <<'PY'
import re, sys
path, sha, checksum = sys.argv[1:]
text = open(path, encoding="utf-8").read()
target = re.search(r'name:\s*"CCmuxAppFFI".*?checksum:\s*"[0-9a-f]{64}"', text, re.S)
if not target:
    sys.exit(f"error: no CCmuxAppFFI binary target with a checksum in {path}")
block = re.sub(r"cmux-app-ffi-[0-9a-f]{40}", f"cmux-app-ffi-{sha}", target.group(0))
block = re.sub(r'checksum:\s*"[0-9a-f]{64}"', f'checksum: "{checksum}"', block)
open(path, "w", encoding="utf-8").write(text[:target.start()] + block + text[target.end():])
PY
echo "pinned CCmuxAppFFI to cmux-app-ffi-$sha ($checksum)"
