#!/usr/bin/env bash
set -euo pipefail

# Compare the old Swift cmux-cli executable with the Rust replacement. The
# app-copy measurement is intentionally separate: compression and code signing
# can make the embedded artifact differ from the release build output.
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_path="$root_dir/Resources/bin/cmux"
rust_path="$root_dir/Native/CmuxCLI/target/release/cmux"
app_path=""
json_output=0
require_all=0

usage() {
  cat <<'EOF'
Usage: scripts/measure-cli-size.sh [options]

Options:
  --swift PATH       Existing Swift CLI binary (default: Resources/bin/cmux)
  --rust PATH        Rust release CLI binary (default: Native/CmuxCLI/target/release/cmux)
  --app PATH         Embedded app copy, or an app bundle containing Resources/bin/cmux
  --json             Emit machine-readable JSON
  --require          Fail when any requested artifact is missing
  -h, --help         Show this help
EOF
}

while (($#)); do
  case "$1" in
    --swift) swift_path="${2:?--swift requires a path}"; shift 2 ;;
    --rust) rust_path="${2:?--rust requires a path}"; shift 2 ;;
    --app) app_path="${2:?--app requires a path}"; shift 2 ;;
    --json) json_output=1; shift ;;
    --require) require_all=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -d "$app_path" ]]; then
  if [[ -x "$app_path/Contents/Resources/bin/cmux" ]]; then
    app_path="$app_path/Contents/Resources/bin/cmux"
  else
    # Do not substitute Contents/MacOS/cmux: that is the app executable, not
    # its CLI, and would produce a plausible but false size comparison.
    app_path="$app_path/Contents/Resources/bin/cmux"
  fi
fi

size_or_null() {
  local path="$1"
  if [[ -f "$path" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then stat -f '%z' "$path"; else stat -c '%s' "$path"; fi
  else
    printf 'null'
  fi
}

swift_bytes="$(size_or_null "$swift_path")"
rust_bytes="$(size_or_null "$rust_path")"
app_bytes="null"
if [[ -n "$app_path" ]]; then app_bytes="$(size_or_null "$app_path")"; fi

if ((require_all)); then
  missing=()
  [[ "$swift_bytes" == null ]] && missing+=("Swift:$swift_path")
  [[ "$rust_bytes" == null ]] && missing+=("Rust:$rust_path")
  [[ -n "$app_path" && "$app_bytes" == null ]] && missing+=("app:$app_path")
  if ((${#missing[@]})); then
    printf 'error: missing artifact(s): %s\n' "${missing[*]}" >&2
    exit 1
  fi
fi

if ((json_output)); then
  python3 -c 'import json,sys
swift,rust,app,sb,rb,ab=sys.argv[1:]
def integer(v): return None if v == "null" else int(v)
s,r,a=integer(sb),integer(rb),integer(ab)
print(json.dumps({"swift":{"path":swift,"bytes":s},"rust_release":{"path":rust,"bytes":r},"app_copy":{"path":app or None,"bytes":a},"delta_bytes":None if s is None or r is None else r-s,"delta_percent":None if not s else (r-s)*100.0/s},indent=2,sort_keys=True))' \
    "$swift_path" "$rust_path" "$app_path" "$swift_bytes" "$rust_bytes" "$app_bytes"
else
  printf 'Swift CLI:  %s bytes  %s\n' "$swift_bytes" "$swift_path"
  printf 'Rust CLI:   %s bytes  %s\n' "$rust_bytes" "$rust_path"
  if [[ -n "$app_path" ]]; then printf 'App copy:   %s bytes  %s\n' "$app_bytes" "$app_path"; fi
  if [[ "$swift_bytes" != null && "$rust_bytes" != null ]]; then
    python3 -c 'import sys
s,r=map(int,sys.argv[1:]); delta=r-s; pct=(delta*100.0/s) if s else 0.0
print(f"Delta:      {delta:+d} bytes ({pct:+.2f}%)")' "$swift_bytes" "$rust_bytes"
  fi
fi
