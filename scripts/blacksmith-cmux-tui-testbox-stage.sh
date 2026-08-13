#!/usr/bin/env bash
set -euo pipefail

# This helper is intentionally remote-only. The local benchmark plan invokes it
# through `blacksmith testbox run`; the guard makes an accidental local launch a
# no-op instead of running a Rust build on the developer's Mac.
if [[ "${CMUX_TESTBOX_REMOTE:-}" != "1" ]]; then
  echo "refusing to run outside a Blacksmith Testbox (set CMUX_TESTBOX_REMOTE=1 only in the remote command)" >&2
  exit 64
fi

if [[ $# -ne 1 ]]; then
  echo "usage: CMUX_TESTBOX_REMOTE=1 $0 {first-clean|incremental-noop|changed-file}" >&2
  exit 64
fi

stage="$1"
case "$stage" in
  first-clean|incremental-noop|changed-file) ;;
  *)
    echo "unsupported benchmark stage: $stage" >&2
    exit 64
    ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
if [[ ! -f cmux-tui/Cargo.toml || ! -f ghostty/.git || ! -f ghostty/build.zig.zon ]]; then
  echo "cmux-tui and its Ghostty source submodule must be initialized" >&2
  exit 65
fi

benchmark_dir="$repo_root/testbox-benchmark"
mkdir -p "$benchmark_dir"
# Testbox can acknowledge a run while its remote shell is still flushing
# output. Serialize stages and hold the lock through artifact writes so a
# subsequent run cannot overwrite a prior stage's timing file.
exec 9>"$benchmark_dir/.stage.lock"
flock -x 9
log_path="$benchmark_dir/$stage.log"
time_path="$benchmark_dir/$stage.time"
json_path="$benchmark_dir/$stage.json"
changed_file="cmux-tui/crates/cmux-tui/src/main.rs"
changed_backup=""

# shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
restore_changed_file() {
  if [[ -n "$changed_backup" && -f "$changed_backup" ]]; then
    cp "$changed_backup" "$repo_root/$changed_file"
    rm -f "$changed_backup"
  fi
}
trap restore_changed_file EXIT

case "$stage" in
  first-clean)
    rm -rf "$repo_root/cmux-tui/target"
    ;;
  changed-file)
    changed_backup="$(mktemp "${TMPDIR:-/tmp}/cmux-tui-testbox-source.XXXXXX")"
    cp "$repo_root/$changed_file" "$changed_backup"
    printf '\n// Blacksmith Testbox changed-file timing marker.\n' >> "$repo_root/$changed_file"
    ;;
esac

start_epoch="$(python3 -c 'import time; print(time.time())')"
set +e
(
  cd "$repo_root/cmux-tui"
  /usr/bin/time -p -o "$time_path" cargo build -p cmux-tui --locked
) >"$log_path" 2>&1
status=$?
set -e
end_epoch="$(python3 -c 'import time; print(time.time())')"

python3 - "$stage" "$start_epoch" "$end_epoch" "$status" "$time_path" "$changed_file" >"$json_path" <<'PY'
import datetime as dt
import json
import os
import platform
import subprocess
import sys

stage, start, end, status, time_path, changed_file = sys.argv[1:]
start = float(start)
end = float(end)
status = int(status)
remote_time = {}
with open(time_path, encoding="utf-8") as handle:
    for line in handle:
        key, _, value = line.strip().partition(" ")
        if key in {"real", "user", "sys"}:
            remote_time[f"time_{key}_seconds"] = float(value)

try:
    git_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
    ).strip()
except subprocess.CalledProcessError:
    git_sha = "unknown"

record = {
    "schema": 1,
    "stage": stage,
    "command": "cargo build -p cmux-tui --locked",
    "exit_code": status,
    "ok": status == 0,
    "started_at": dt.datetime.fromtimestamp(start, dt.timezone.utc).isoformat(),
    "finished_at": dt.datetime.fromtimestamp(end, dt.timezone.utc).isoformat(),
    "wall_seconds": round(end - start, 3),
    "git_sha": git_sha,
    "runner": {
        "hostname": platform.node(),
        "arch": platform.machine(),
        "cpu_count": os.cpu_count(),
        "uname": " ".join(platform.uname()),
    },
    "changed_file": changed_file if stage == "changed-file" else None,
    **remote_time,
}
print(json.dumps(record, sort_keys=True))
PY

cat "$log_path"
printf '\n--- /usr/bin/time -p (%s) ---\n' "$stage"
cat "$time_path"
printf '\n--- structured timing (%s) ---\n' "$stage"
cat "$json_path"
exit "$status"
