#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <testbox-id> <evidence-directory> <confirmation-token>" >&2
  exit 64
fi

testbox_id="$1"
evidence_dir="$2"
confirmation_token="$3"
if [[ ! "$testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]]; then
  echo "invalid Testbox ID: $testbox_id" >&2
  exit 64
fi
if [[ ! "$confirmation_token" =~ ^[0-9a-f]{32}$ ]]; then
  echo "confirmation token must be a 32-character lowercase hex value" >&2
  exit 64
fi

mkdir -p "$evidence_dir"
receipt_path="$evidence_dir/testbox-receipt.json"
if [[ ! -s "$receipt_path" ]]; then
  echo "refusing cleanup without the warmup ownership receipt: $receipt_path" >&2
  exit 65
fi
python3 - "$receipt_path" "$testbox_id" "$confirmation_token" <<'PY'
import json
import pathlib
import sys

receipt_path, expected_id, expected_token = sys.argv[1:]
try:
    receipt = json.loads(pathlib.Path(receipt_path).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid warmup ownership receipt: {error}")
if receipt.get("testbox_id") != expected_id:
    raise SystemExit("cleanup ID does not match the warmup ownership receipt")
if receipt.get("confirmation_token") != expected_token:
    raise SystemExit("cleanup confirmation token does not match the warmup ownership receipt")
for field in ("workflow", "job", "source_ref", "source_sha", "source_tree_sha", "ghostty_gitlink_sha"):
    if not receipt.get(field):
        raise SystemExit(f"warmup ownership receipt is missing {field}")
PY
stop_log="$evidence_dir/stop.log"
status_log="$evidence_dir/status-after-stop.log"
list_log="$evidence_dir/list-after-stop.log"
cleanup_status=0

set +e
blacksmith testbox stop --id "$testbox_id" >"$stop_log" 2>&1
stop_status=$?
set -e
if (( stop_status != 0 )); then
  # A completed Testbox can race the explicit stop call. Tolerate only the
  # documented terminal-state response, never an arbitrary stop failure.
  if grep -Eiq 'already[[:space:]]+(stopped|completed)' "$stop_log"; then
    printf 'stop already reached a terminal state for %s; continuing\n' "$testbox_id" >&2
  else
    echo "failed to stop Testbox $testbox_id; see $stop_log" >&2
    cleanup_status=$stop_status
  fi
fi

# Status is diagnostic. The authoritative cleanup check below parses the
# specific ID in `list --all`; terminal rows are accepted because --all may
# retain completed boxes, while active rows remain failures.
set +e
blacksmith testbox status --id "$testbox_id" >"$status_log" 2>&1
status_status=$?
set -e
if (( status_status == 0 )); then
  status_value="$(awk -v id="$testbox_id" '$1 == id { print tolower($2); exit }' "$status_log")"
  case "$status_value" in
    completed|stopped|cancelled|failed|terminated)
      ;;
    ready|running|hydrating|in_progress|queued)
      echo "Testbox $testbox_id is still active after cleanup" >&2
      (( cleanup_status == 0 )) && cleanup_status=1
      ;;
    *)
      if grep -Eiq 'status:[[:space:]]*(completed|stopped|cancelled|failed|terminated)' "$status_log"; then
        :
      else
        echo "could not establish a terminal status for Testbox $testbox_id; see $status_log" >&2
        (( cleanup_status == 0 )) && cleanup_status=1
      fi
      ;;
  esac
elif ! grep -Eiq '(not found|already[[:space:]]+(stopped|completed)|HTTP[[:space:]]+409|status[[:space:]]+code[[:space:]]+409)' "$status_log"; then
  echo "failed to inspect Testbox $testbox_id; see $status_log" >&2
  (( cleanup_status == 0 )) && cleanup_status=$status_status
fi

set +e
blacksmith testbox list --all >"$list_log" 2>&1
list_status=$?
set -e
if (( list_status != 0 )); then
  echo "failed to list Testboxes after stopping $testbox_id; see $list_log" >&2
  (( cleanup_status == 0 )) && cleanup_status=$list_status
else
  listed_status="$(awk -v id="$testbox_id" '$1 == id { print tolower($2); exit }' "$list_log")"
  case "$listed_status" in
    "")
      # The CLI may remove terminal boxes from the inventory immediately.
      ;;
    completed|stopped|cancelled|failed|terminated)
      # --all is the full inventory, so a terminal row is safe and expected.
      ;;
    ready|running|hydrating|in_progress|queued)
      echo "Testbox $testbox_id is still active after cleanup; see $list_log" >&2
      (( cleanup_status == 0 )) && cleanup_status=1
      ;;
    *)
      echo "unknown status for Testbox $testbox_id in inventory: $listed_status" >&2
      (( cleanup_status == 0 )) && cleanup_status=1
      ;;
  esac
fi

if (( cleanup_status != 0 )); then
  exit "$cleanup_status"
fi
printf 'verified Testbox %s is no longer active\n' "$testbox_id"
