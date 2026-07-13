#!/usr/bin/env bash
# Regression test for the Ghostty Zig version guard used by setup scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/check-zig-version.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"

write_zig_stub() {
  local version="$1"
  cat > "$BIN_DIR/zig" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "version" ]]; then
  printf '%s\n' '$version'
  exit 0
fi
echo "unexpected zig invocation: \$*" >&2
exit 1
EOF
  chmod +x "$BIN_DIR/zig"
}

run_guard() {
  local installed_version="$1"
  local required_version="$2"
  local output_file="$3"

  write_zig_stub "$installed_version"
  PATH="$BIN_DIR:/usr/bin:/bin" "$SCRIPT" "$required_version" >"$output_file" 2>&1
}

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT must be executable"
  exit 1
fi

for file in "$ROOT_DIR/scripts/setup.sh" "$ROOT_DIR/scripts/ensure-ghosttykit.sh"; do
  if ! grep -Fq 'check-zig-version.sh' "$file"; then
    echo "FAIL: $file must invoke check-zig-version.sh"
    exit 1
  fi
done

if ! run_guard "0.15.2" "0.15.2" "$TMP_DIR/exact.out"; then
  cat "$TMP_DIR/exact.out"
  echo "FAIL: guard rejected the exact required Zig version"
  exit 1
fi

if ! run_guard "0.15.3" "0.15.2" "$TMP_DIR/patch.out"; then
  cat "$TMP_DIR/patch.out"
  echo "FAIL: guard rejected a newer patch in the required Zig minor"
  exit 1
fi

if run_guard "0.15.1" "0.15.2" "$TMP_DIR/old-patch.out"; then
  echo "FAIL: guard accepted an older patch than Ghostty requires"
  exit 1
fi
if ! grep -Fq "cmux requires Zig 0.15.x with patch >= 2" "$TMP_DIR/old-patch.out"; then
  cat "$TMP_DIR/old-patch.out"
  echo "FAIL: older-patch error did not explain the required Zig range"
  exit 1
fi

if run_guard "0.16.0" "0.15.2" "$TMP_DIR/new-minor.out"; then
  echo "FAIL: guard accepted a different Zig minor version"
  exit 1
fi
if ! grep -Fq "found 0.16.0" "$TMP_DIR/new-minor.out"; then
  cat "$TMP_DIR/new-minor.out"
  echo "FAIL: minor-mismatch error did not include the installed Zig version"
  exit 1
fi

NO_ZIG_BIN="$TMP_DIR/no-zig-bin"
mkdir -p "$NO_ZIG_BIN"
ln -s "$(command -v dirname)" "$NO_ZIG_BIN/dirname"
if PATH="$NO_ZIG_BIN" /bin/bash "$SCRIPT" "0.15.2" >"$TMP_DIR/missing.out" 2>&1; then
  echo "FAIL: guard accepted a missing zig binary"
  exit 1
fi
if ! grep -Fq "cmux requires Zig 0.15.x with patch >= 2, but zig is not installed" "$TMP_DIR/missing.out"; then
  cat "$TMP_DIR/missing.out"
  echo "FAIL: missing-zig error did not include the required version"
  exit 1
fi

if run_guard "0.15.2-dev.1" "0.15.2" "$TMP_DIR/dev-suffix.out"; then
  echo "FAIL: guard accepted a non-release Zig version string"
  exit 1
fi
if ! grep -Fq "could not parse installed Zig version" "$TMP_DIR/dev-suffix.out"; then
  cat "$TMP_DIR/dev-suffix.out"
  echo "FAIL: non-release version error did not explain the parse failure"
  exit 1
fi

if grep -Fq 'CMUX_ZIG_VERSION_CHECKED' "$ROOT_DIR/scripts/ensure-ghosttykit.sh" "$ROOT_DIR/scripts/setup.sh"; then
  echo "FAIL: setup scripts should not allow an ambient environment flag to bypass Zig validation"
  exit 1
fi

if grep -Fq 'CMUX_REQUIRED_ZIG_VERSION' "$SCRIPT"; then
  echo "FAIL: an ambient environment variable must not override Ghostty's Zig requirement"
  exit 1
fi

REQUIRED_FROM_GHOSTTY="$(python3 - "$ROOT_DIR/ghostty/build.zig.zon" <<'PY'
from pathlib import Path
import re
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', text)
if not match:
    raise SystemExit("missing .minimum_zig_version")
print(match.group(1))
PY
)"

write_zig_stub "99.99.99"
if CMUX_ZIG_VERSION_CHECKED=1 \
  CMUX_REQUIRED_ZIG_VERSION=99.99.99 \
  PATH="$BIN_DIR:/usr/bin:/bin" \
  "$SCRIPT" >"$TMP_DIR/ambient-bypass.out" 2>&1; then
  echo "FAIL: legacy environment overrides bypassed Ghostty's Zig requirement"
  exit 1
fi
if ! grep -Fq "found 99.99.99" "$TMP_DIR/ambient-bypass.out"; then
  cat "$TMP_DIR/ambient-bypass.out"
  echo "FAIL: runtime bypass test did not exercise the incompatible Zig path"
  exit 1
fi

write_zig_stub "$REQUIRED_FROM_GHOSTTY"
if ! PATH="$BIN_DIR:/usr/bin:/bin" "$SCRIPT" >"$TMP_DIR/from-ghostty.out" 2>&1; then
  cat "$TMP_DIR/from-ghostty.out"
  echo "FAIL: guard did not read the required version from ghostty/build.zig.zon"
  exit 1
fi

if ! grep -Fq "satisfies Ghostty requirement $REQUIRED_FROM_GHOSTTY" "$TMP_DIR/from-ghostty.out"; then
  cat "$TMP_DIR/from-ghostty.out"
  echo "FAIL: guard output did not mention the Ghostty-required version"
  exit 1
fi

echo "PASS: Zig version guard enforces Ghostty's major/minor requirement"
