#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/create_release_dmg.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: missing executable script $SCRIPT"
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/create-dmg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
  if [ "${FAKE_MODE:-}" = "legacy" ]; then
    echo "create-dmg 1.2.1"
  else
    echo "create-dmg 8.0.0"
  fi
  exit 0
fi

printf '%s\n' "$*" >> "$FAKE_LOG"

if [ "${FAKE_MODE:-}" = "legacy" ]; then
  for arg in "$@"; do
    if [[ "$arg" == *.dmg ]]; then
      mkdir -p "$(dirname "$arg")"
      : > "$arg"
      exit 0
    fi
  done
  echo "fake legacy create-dmg did not receive an output .dmg argument" >&2
  exit 1
fi

dest="${!#}"
mkdir -p "$dest"
: > "$dest/generated.dmg"
EOF
chmod +x "$TMPDIR/bin/create-dmg"

APP_DIR="$TMPDIR/cmux.app"
mkdir -p "$APP_DIR/Contents"

run_case() {
  local mode log_file output_path
  mode="$1"
  log_file="$TMPDIR/${mode}.log"
  output_path="$TMPDIR/${mode}/cmux-macos.dmg"

  PATH="$TMPDIR/bin:$PATH" FAKE_MODE="$mode" FAKE_LOG="$log_file" \
    "$SCRIPT" "$APP_DIR" "$output_path" "SIGNING-ID"

  if [ ! -f "$output_path" ]; then
    echo "FAIL: ${mode} mode did not produce $output_path"
    exit 1
  fi

  if [ "$mode" = "legacy" ]; then
    grep -F -- "--app-drop-link 480 170" "$log_file" >/dev/null || {
      echo "FAIL: legacy mode did not add Applications drop link"
      exit 1
    }
    grep -F -- "--codesign SIGNING-ID" "$log_file" >/dev/null || {
      echo "FAIL: legacy mode did not pass --codesign"
      exit 1
    }
  else
    grep -F -- "--overwrite" "$log_file" >/dev/null || {
      echo "FAIL: modern mode did not pass --overwrite"
      exit 1
    }
    grep -F -- "--identity=SIGNING-ID" "$log_file" >/dev/null || {
      echo "FAIL: modern mode did not pass --identity"
      exit 1
    }
  fi
}

run_case legacy
run_case modern

echo "PASS: create_release_dmg script handles legacy and modern create-dmg"
