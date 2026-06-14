#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/mobile-stability-soak/final-audit-watcher.sh <soak-root> [--required-seconds N]

Polls audit.json until the soak reaches passed/failed. On completion or failure,
runs final-audit.py and writes final-audit.json plus final-audit.log in the soak root.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

root="$1"
shift
required_seconds=43200

while (( $# > 0 )); do
  case "$1" in
    --required-seconds)
      required_seconds="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
audit_path="$root/audit.json"
final_json="$root/final-audit.json"
final_log="$root/final-audit.log"

mkdir -p "$root"

run_final_audit() {
  local tmp
  tmp="$(mktemp "$root/final-audit.XXXXXX")"
  if "$script_dir/final-audit.py" "$root" --required-seconds "$required_seconds" >"$tmp" 2>"$final_log"; then
    mv "$tmp" "$final_json"
    exit 0
  else
    local status=$?
    mv "$tmp" "$final_json"
    exit "$status"
  fi
}

while true; do
  if [[ ! -f "$audit_path" ]]; then
    sleep 60
    continue
  fi

  status="$(/usr/bin/python3 - "$audit_path" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get("status", "invalid"))
except Exception:
    print("invalid")
PY
)"

  case "$status" in
    passed|failed)
      run_final_audit
      ;;
  esac

  sleep 60
done
