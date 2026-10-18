#!/usr/bin/env bash
# The committed inspector page is a Cargo build-script input. Rebuilding the
# same bytes must not rewrite it: Cargo uses its mtime for rerun-if-changed and
# an unnecessary write invalidates the OptChat Chief incremental build.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/scripts/cmux-next" "$REPO/webviews/src/optchat-inspector" "$REPO/webviews/node_modules" "$TMP/bin"
cp "$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" "$REPO/scripts/cmux-next/"
cp "$ROOT/scripts/check-webviews-bun-version.sh" "$REPO/scripts/"
cat > "$REPO/webviews/package.json" <<'JSON'
{"devEngines":{"packageManager":{"name":"bun","version":"1.4.2"}}}
JSON
printf 'body { color: black; }\n' > "$REPO/webviews/src/optchat-inspector/styles.css"
printf 'export const inspector = true;\n' > "$REPO/webviews/src/optchat-inspector/main.tsx"

# This fake only replaces the expensive esbuild invocation. The generated
# payload is controlled by an environment variable so the test can prove both
# the unchanged-byte and changed-byte paths without installing webviews deps.
cat > "$TMP/bin/bun" <<'SH'
#!/bin/sh
set -eu
case "${1:-}" in
  --version) printf '1.4.2\n' ;;
  -e) printf '1.4.2\n' ;;
  x)
    outfile=""
    for arg in "$@"; do
      case "$arg" in --outfile=*) outfile=${arg#--outfile=} ;; esac
    done
    [ -n "$outfile" ] || { echo 'missing --outfile' >&2; exit 2; }
    printf '%s\n' "${FAKE_BUN_PAYLOAD:-const app = true;}" > "$outfile"
    ;;
  *) echo "unexpected bun invocation: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$TMP/bin/bun"

OUT="$REPO/Native/OptChat/optchat-chief/inspector"
PATH="$TMP/bin:$PATH" "$REPO/scripts/cmux-next/build-optchat-inspector-web.sh" --out "$OUT" >/dev/null
first=$(python3 - "$OUT/index.html" <<'PY'
import os, sys
print(os.stat(sys.argv[1]).st_mtime_ns)
PY
)
# Use a fixed old timestamp so a cp-based implementation cannot accidentally
# pass when the filesystem has coarse timestamp resolution.
python3 - "$OUT/index.html" <<'PY'
import os, sys
stamp = 1_000_000_000_000_000_000
os.utime(sys.argv[1], ns=(stamp, stamp))
PY
PATH="$TMP/bin:$PATH" "$REPO/scripts/cmux-next/build-optchat-inspector-web.sh" --out "$OUT" >/dev/null
second=$(python3 - "$OUT/index.html" <<'PY'
import os, sys
print(os.stat(sys.argv[1]).st_mtime_ns)
PY
)
[ "$second" = 1000000000000000000 ] || {
  echo "FAIL: identical inspector output rewrote its mtime ($second; first build mtime $first)" >&2
  exit 1
}

FAKE_BUN_PAYLOAD='const app = false;' PATH="$TMP/bin:$PATH" \
  "$REPO/scripts/cmux-next/build-optchat-inspector-web.sh" --out "$OUT" >/dev/null
grep -q 'const app = false;' "$OUT/index.html" || {
  echo 'FAIL: changed inspector output was not installed' >&2
  exit 1
}
third=$(python3 - "$OUT/index.html" <<'PY'
import os, sys
print(os.stat(sys.argv[1]).st_mtime_ns)
PY
)
[ "$third" -gt 1000000000000000000 ] || {
  echo "FAIL: changed inspector output did not receive a fresh mtime ($third)" >&2
  exit 1
}

echo 'PASS: identical inspector output preserves mtime; changed output is installed'
