#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <testbox-id> <evidence-directory> <ownership-token> <PREVIEW|STOP:preview-sha>" >&2
  exit 64
fi

testbox_id="$1"
evidence_dir="$2"
ownership_token="$3"
operator_confirmation="$4"
if [[ ! "$testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]]; then
  echo "invalid Testbox ID: $testbox_id" >&2
  exit 64
fi
if [[ ! "$ownership_token" =~ ^[0-9a-f]{32}$ ]]; then
  echo "ownership token must be a 32-character lowercase hex value" >&2
  exit 64
fi
if [[ "$operator_confirmation" != "PREVIEW" && ! "$operator_confirmation" =~ ^STOP:[0-9a-f]{64}$ ]]; then
  echo "confirmation must be PREVIEW or STOP:<64-character preview SHA>" >&2
  exit 64
fi

mkdir -p "$evidence_dir"
sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "sha256sum or shasum is required for cleanup preview hashing" >&2
    return 65
  fi
}
bounded_command() {
  scripts_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  "$scripts_dir/blacksmith-bounded-command.sh" "$@"
}
receipt_path="$evidence_dir/testbox-receipt.json"
if [[ ! -s "$receipt_path" ]]; then
  echo "refusing cleanup without the warmup ownership receipt: $receipt_path" >&2
  exit 65
fi
python3 - "$receipt_path" "$testbox_id" "$ownership_token" <<'PY'
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
    raise SystemExit("ownership token does not match the warmup ownership receipt")
# warmup_ref is what `blacksmith testbox list` shows and is always main in the
# broker lane. source_ref is the branch being benchmarked and never appears in
# the inventory. Conflating them made every receipt-bound cleanup exit 66.
for field in ("workflow", "job", "warmup_ref", "source_ref", "source_sha", "source_tree_sha", "ghostty_gitlink_sha"):
    if not receipt.get(field):
        raise SystemExit(f"warmup ownership receipt is missing {field}")
PY
receipt_workflow="$(python3 - "$receipt_path" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["workflow"])
PY
)"
receipt_job="$(python3 - "$receipt_path" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["job"])
PY
)"
receipt_ref="$(python3 - "$receipt_path" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["warmup_ref"])
PY
)"
receipt_source_ref="$(python3 - "$receipt_path" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["source_ref"])
PY
)"
receipt_source_sha="$(python3 - "$receipt_path" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["source_sha"])
PY
)"
receipt_source_tree_sha="$(python3 - "$receipt_path" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["source_tree_sha"])
PY
)"
receipt_ghostty_sha="$(python3 - "$receipt_path" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["ghostty_gitlink_sha"])
PY
)"

# Parse either the table emitted by `list/status --id` or a summary response.
# The parser validates context only for a row containing this exact ID. It does
# not rely on fixed whitespace columns, because queued rows may have an empty IP.
parse_cli_output() {
  local log_path="$1"
  python3 - "$log_path" "$testbox_id" "$receipt_workflow" "$receipt_job" "$receipt_ref" <<'PY'
import pathlib
import re
import sys

path, expected_id, expected_workflow, expected_job, expected_ref = sys.argv[1:]
text = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
for line in text.splitlines():
    fields = line.split()
    if not fields or fields[0] != expected_id:
        continue
    if len(fields) < 2:
        raise SystemExit(66)
    status = fields[1].lower()
    # Blacksmith CLI releases have emitted both ID/STATUS/REPO/WORKFLOW/CREATED
    # and ID/STATUS/IP/WORKFLOW/JOB/REF/... schemas. Require the exact workflow
    # in either schema; when job/ref columns exist, require those too.
    try:
        workflow_index = fields.index(expected_workflow, 2)
    except ValueError:
        raise SystemExit(66)
    trailing = fields[workflow_index + 1:]
    # Known schemas either end after CREATED (no job/ref columns) or expose
    # JOB and REF immediately after WORKFLOW. If either expected field appears,
    # require the exact pair in the exact order; reject all ambiguous contexts.
    if len(trailing) >= 2 and trailing[:2] == [expected_job, expected_ref]:
        pass
    elif expected_job in trailing or expected_ref in trailing:
        raise SystemExit(66)
    elif len(trailing) not in (1, 2):
        raise SystemExit(66)
    print(status)
    raise SystemExit(0)

# Some CLI versions use a summary such as `[tbx_...] Status: ready`.
if re.search(rf"\b{re.escape(expected_id)}\b", text):
    match = re.search(r"\bstatus\s*:?\s*([A-Za-z_]+)", text, re.IGNORECASE)
    if match:
        print(match.group(1).lower())
        raise SystemExit(0)
raise SystemExit(3)
PY
}

is_terminal() {
  case "$1" in
    completed|stopped|cancelled|failed|terminated|hydration_failed) return 0 ;;
    *) return 1 ;;
  esac
}
is_active() {
  case "$1" in
    ready|running|hydrating|in_progress|queued) return 0 ;;
    *) return 1 ;;
  esac
}
is_known_absence() {
  grep -Eiq '(not found|already[[:space:]]+(stopped|completed)|hydration_failed|HTTP[[:space:]]+404|status[[:space:]]+code[[:space:]]+404|HTTP[[:space:]]+409|status[[:space:]]+code[[:space:]]+409)' "$1"
}

inventory_log="$evidence_dir/list-before-stop.log"
set +e
bounded_command 20 blacksmith testbox list --all >"$inventory_log" 2>&1
inventory_status=$?
set -e
if (( inventory_status != 0 )); then
  echo "failed to capture the Testbox inventory before cleanup; refusing stop" >&2
  exit "$inventory_status"
fi

inventory_row_present=0
set +e
parse_cli_output "$inventory_log" >/dev/null
inventory_parse_status=$?
set -e
case "$inventory_parse_status" in
  0) inventory_row_present=1 ;;
  3) : ;;
  66) echo "inventory ownership context differs from the warmup receipt; refusing cleanup" >&2; exit 66 ;;
  *) echo "could not parse the Testbox inventory; refusing cleanup" >&2; exit "$inventory_parse_status" ;;
esac

status_log="$evidence_dir/status-before-stop.log"
set +e
bounded_command 20 blacksmith testbox status --id "$testbox_id" >"$status_log" 2>&1
status_command_status=$?
set -e
status_value=""
status_absent=0
if (( status_command_status == 0 )); then
  set +e
  status_value="$(parse_cli_output "$status_log")"
  status_parse_status=$?
  set -e
  case "$status_parse_status" in
    0) ;;
    3) echo "status omitted the owned Testbox $testbox_id; refusing cleanup" >&2; exit 66 ;;
    66) echo "status ownership context differs from the warmup receipt; refusing cleanup" >&2; exit 66 ;;
    *) echo "could not parse status for owned Testbox $testbox_id; refusing cleanup" >&2; exit "$status_parse_status" ;;
  esac
elif is_known_absence "$status_log"; then
  status_absent=1
else
  echo "failed to inspect owned Testbox $testbox_id before cleanup; refusing stop" >&2
  exit "$status_command_status"
fi

if (( status_absent == 0 )) && is_active "$status_value" && (( inventory_row_present == 0 )); then
  echo "owned Testbox is active but absent from the inventory; refusing cleanup" >&2
  exit 66
fi
if (( status_absent == 0 )) && ! is_active "$status_value" && ! is_terminal "$status_value"; then
  echo "unknown status for owned Testbox $testbox_id; refusing cleanup" >&2
  exit 66
fi

preview_path="$evidence_dir/cleanup-preview.json"
python3 - "$preview_path" "$testbox_id" "${status_value:-absent}" "$inventory_row_present" "$receipt_workflow" "$receipt_job" "$receipt_ref" "$receipt_source_ref" "$receipt_source_sha" "$receipt_source_tree_sha" "$receipt_ghostty_sha" <<'PY'
import json
import pathlib
import sys

(path, testbox_id, status, inventory_present, workflow, job, warmup_ref,
 source_ref, source_sha, source_tree_sha, ghostty_sha) = sys.argv[1:]
payload = {
    "schema": 2,
    "testbox_id": testbox_id,
    "status": status,
    "inventory_row_present": bool(int(inventory_present)),
    "workflow": workflow,
    "job": job,
    # The ref the box was warmed from, which is what the inventory row shows.
    "warmup_ref": warmup_ref,
    # The branch actually benchmarked. Pairing warmup_ref with source_sha made
    # the destruction record claim a SHA that is not on the ref beside it.
    "source_ref": source_ref,
    "source_sha": source_sha,
    "source_tree_sha": source_tree_sha,
    "ghostty_gitlink_sha": ghostty_sha,
}
out = pathlib.Path(path)
out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
out.chmod(0o600)
PY
preview_sha="$(sha256_file "$preview_path" | awk '{print $1}')"
printf 'Testbox cleanup preview: id=%s status=%s inventory_row=%s workflow=%s job=%s ref=%s\n' \
  "$testbox_id" "${status_value:-absent}" "$inventory_row_present" "$receipt_workflow" "$receipt_job" "$receipt_ref"
printf 'Preview SHA: %s\n' "$preview_sha"
if [[ "$operator_confirmation" == "PREVIEW" ]]; then
  echo "Review the preview, then rerun with the same token and STOP:$preview_sha to authorize stop." >&2
  exit 75
fi
expected_preview_sha="${operator_confirmation#STOP:}"
if [[ "$operator_confirmation" != "PREVIEW" && "$expected_preview_sha" != "$preview_sha" ]]; then
  echo "current cleanup preview differs from the supplied confirmation; refusing stop" >&2
  exit 67
fi

# The pre-stop status is evidence of when the box was alive. The poll below
# writes to its own file so it cannot overwrite that record.
post_status_log="$evidence_dir/status-after-stop.log"
stop_log="$evidence_dir/stop.log"
list_log="$evidence_dir/list-after-stop.log"
cleanup_status=0
poll_deadline=$((SECONDS + 120))
poll_attempt=0
if (( status_absent == 1 )) || is_terminal "$status_value"; then
  printf 'Testbox %s is already terminal or absent; no stop request needed\n' "$testbox_id" >"$stop_log"
else
  set +e
  bounded_command 20 blacksmith testbox stop --id "$testbox_id" >"$stop_log" 2>&1
  stop_status=$?
  set -e
  if (( stop_status != 0 )); then
    if is_known_absence "$stop_log"; then
      printf 'stop reached a known terminal or absent state for %s; continuing\n' "$testbox_id" >&2
    else
      echo "failed to stop Testbox $testbox_id; see $stop_log" >&2
      cleanup_status=$stop_status
    fi
  fi
fi

# Poll the ID-specific endpoint until cancellation propagates. Never treat a
# different row in the global inventory as proof that this ID is terminal.
while :; do
  poll_attempt=$((poll_attempt + 1))
  : >"$post_status_log"
  set +e
  bounded_command 20 blacksmith testbox status --id "$testbox_id" >"$post_status_log" 2>&1
  status_command_status=$?
  set -e
  if (( status_command_status == 0 )); then
    set +e
    status_value="$(parse_cli_output "$post_status_log")"
    status_parse_status=$?
    set -e
    if (( status_parse_status != 0 )); then
      echo "could not parse post-stop status for $testbox_id; see $post_status_log" >&2
      (( cleanup_status == 0 )) && cleanup_status=66
      break
    fi
    if is_terminal "$status_value"; then
      break
    fi
    if ! is_active "$status_value"; then
      echo "unknown post-stop status for $testbox_id; see $post_status_log" >&2
      (( cleanup_status == 0 )) && cleanup_status=66
      break
    fi
  elif is_known_absence "$post_status_log"; then
    break
  else
    echo "failed to inspect Testbox $testbox_id after cleanup; see $post_status_log" >&2
    (( cleanup_status == 0 )) && cleanup_status=$status_command_status
    break
  fi
  if (( SECONDS >= poll_deadline )); then
    echo "Testbox $testbox_id is still active after bounded cleanup polling" >&2
    (( cleanup_status == 0 )) && cleanup_status=1
    break
  fi
  sleep_seconds=$((poll_attempt < 6 ? poll_attempt * 2 : 10))
  sleep "$sleep_seconds"
done

set +e
bounded_command 20 blacksmith testbox list --all >"$list_log" 2>&1
list_status=$?
set -e
if (( list_status != 0 )); then
  echo "failed to list Testboxes after stopping $testbox_id; see $list_log" >&2
  (( cleanup_status == 0 )) && cleanup_status=$list_status
else
  set +e
  listed_status="$(parse_cli_output "$list_log")"
  listed_parse_status=$?
  set -e
  case "$listed_parse_status" in
    0)
      if is_active "$listed_status"; then
        echo "Testbox $testbox_id is still active after cleanup; see $list_log" >&2
        (( cleanup_status == 0 )) && cleanup_status=1
      elif ! is_terminal "$listed_status"; then
        echo "unknown status for Testbox $testbox_id in inventory: $listed_status" >&2
        (( cleanup_status == 0 )) && cleanup_status=66
      fi
      ;;
    3) ;;
    66)
      echo "Testbox $testbox_id ownership changed in final inventory; see $list_log" >&2
      (( cleanup_status == 0 )) && cleanup_status=66
      ;;
    *)
      echo "could not parse final Testbox inventory; see $list_log" >&2
      (( cleanup_status == 0 )) && cleanup_status=$listed_parse_status
      ;;
  esac
fi

if (( cleanup_status != 0 )); then
  exit "$cleanup_status"
fi
printf 'verified Testbox %s is no longer active\n' "$testbox_id"
