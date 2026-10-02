#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# This helper is intentionally remote-only. The local benchmark plan invokes it
# through `blacksmith testbox run`; the environment flag is only a first guard.
# The Blacksmith kernel marker and /tmp/.testbox state below are the stronger
# signals that this command is running in the prepared Testbox VM.
if [[ "${CMUX_TESTBOX_REMOTE:-}" != "1" ]]; then
  echo "refusing to run outside a Blacksmith Testbox (set CMUX_TESTBOX_REMOTE=1 only in the remote command)" >&2
  exit 64
fi
if [[ ! -r /proc/cmdline ]] || ! grep -Eq '(^|[[:space:]])metadata_port=[^[:space:]]+' /proc/cmdline; then
  echo "refusing to run without the Blacksmith Testbox metadata marker" >&2
  exit 64
fi

if [[ $# -ne 3 ]]; then
  echo "usage: CMUX_TESTBOX_REMOTE=1 CMUX_TESTBOX_ID=tbx_... $0 {first-clean|incremental-noop|changed-file} <source-sha> <ghostty-gitlink-sha>" >&2
  exit 64
fi

stage="$1"
expected_source_sha="$2"
expected_ghostty_sha="$3"
case "$stage" in
  first-clean|incremental-noop|changed-file) ;;
  *)
    echo "unsupported benchmark stage: $stage" >&2
    exit 64
    ;;
esac

for value_name in expected_source_sha expected_ghostty_sha; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$value_name must be a lowercase 40-character commit SHA" >&2
    exit 64
  fi
done

testbox_id="${CMUX_TESTBOX_ID:-}"
if [[ ! "$testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]]; then
  echo "CMUX_TESTBOX_ID must identify the claimed Testbox" >&2
  exit 64
fi

state_dir=/tmp/.testbox
if [[ ! -d "$state_dir" || ! -s "$state_dir/auth_token" || ! -f "$state_dir/testbox_id" ]]; then
  echo "refusing to run without the Testbox state files" >&2
  exit 64
fi
state_testbox_id="$(tr -d '\r\n' <"$state_dir/testbox_id")"
if [[ "$state_testbox_id" != "$testbox_id" ]]; then
  echo "Testbox state belongs to $state_testbox_id, expected $testbox_id" >&2
  exit 66
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
ghostty_root="$repo_root/ghostty"
if [[ ! -f cmux-tui/Cargo.toml || ! -f ghostty/build.zig.zon ]]; then
  echo "cmux-tui and its Ghostty source submodule must be initialized" >&2
  exit 65
fi
if [[ "$(git -C ghostty rev-parse --show-toplevel 2>/dev/null || true)" != "$ghostty_root" ]]; then
  echo "ghostty is not an initialized submodule checkout" >&2
  exit 65
fi
ghostty_entry="$(git ls-tree HEAD ghostty)"
if [[ ! "$ghostty_entry" =~ ^160000[[:space:]]commit[[:space:]][0-9a-f]{40}[[:space:]]ghostty$ ]]; then
  echo "HEAD:ghostty is not a gitlink" >&2
  exit 65
fi
# Blacksmith's sync copies file contents and only opportunistically fetches the
# benchmarked commit; once the working files match it skips entirely. The box
# therefore keeps the history the warmup job checked out, which is main. Fail
# with the exact remedy instead of an unreadable `git rev-parse` error.
require_benchmarked_commit() {
  cat >&2 <<REMEDY
the benchmarked commit is not checked out on this Testbox
  expected: $expected_source_sha
  present:  $(git rev-parse HEAD 2>/dev/null || echo unknown)
Push the commit, then pin this box to it before running a stage:
  git push origin <branch>
  blacksmith testbox run --id $testbox_id 'set -euo pipefail; git fetch --no-tags origin $expected_source_sha; git reset --hard $expected_source_sha; git submodule update --init --depth 1 ghostty'
REMEDY
  exit 65
}
git rev-parse --verify --quiet "${expected_source_sha}^{commit}" >/dev/null || require_benchmarked_commit
[[ "$(git rev-parse HEAD)" == "$expected_source_sha" ]] || require_benchmarked_commit
expected_tree_sha="$(git rev-parse "${expected_source_sha}^{tree}")"
if ! command -v timeout >/dev/null; then
  echo "timeout is required for bounded remote builds" >&2
  exit 65
fi
setup_identity_path="$state_dir/cmux-tui-rust-setup-identity.json"
if [[ ! -s "$setup_identity_path" ]]; then
  echo "refusing to run without a successful Testbox setup identity marker" >&2
  exit 65
fi
setup_run_id="$(tr -d '\r\n' <"$state_dir/adopted_run_id")"
if [[ ! "$setup_run_id" =~ ^[0-9]+$ ]]; then
  echo "invalid Testbox setup workflow run ID" >&2
  exit 65
fi
# The broker hydrates main, while this stage benchmarks whatever revision the
# operator synchronized onto the box. Those two commits are deliberately
# allowed to differ, so the marker is checked for VM identity, runner class,
# and toolchain completeness, not for source equality. The active-toolchain
# gate further down is what still refuses a candidate whose pinned Rust or Zig
# would leave the hydrated caches cold and the timings incomparable.
verify_setup_identity() {
  python3 - "$setup_identity_path" "$testbox_id" "$setup_run_id" <<'PY'
import json
import pathlib
import re
import sys

path, expected_testbox, expected_run_id = sys.argv[1:]
try:
    record = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid setup identity marker: {error}")
source = record.get("source", {})
testbox = record.get("testbox", {})
runner = record.get("runner", {})
toolchain = record.get("toolchain", {})
errors = []
if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit_sha", ""))):
    errors.append("setup hydration commit is missing or malformed")
if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("tree_sha", ""))):
    errors.append("setup hydration tree is missing or malformed")
if not re.fullmatch(r"[0-9a-f]{40}", str(source.get("ghostty_gitlink_sha", ""))):
    errors.append("setup hydration Ghostty gitlink is missing or malformed")
if source.get("ghostty_head_sha") != source.get("ghostty_gitlink_sha"):
    errors.append("setup hydration Ghostty checkout does not match its own gitlink")
if source.get("ref") != "refs/heads/main":
    errors.append(f"setup hydration ref {source.get('ref')!r} is not refs/heads/main")
if testbox.get("id") != expected_testbox:
    errors.append("setup Testbox ID mismatch")
if str(testbox.get("setup_workflow_run_id")) != expected_run_id:
    errors.append("setup workflow run ID mismatch")
if runner.get("label") != "blacksmith-32vcpu-ubuntu-2404" or runner.get("arch") != "X64" or runner.get("cpu_count") != 32:
    errors.append("setup runner identity mismatch")
if not toolchain.get("rust_toolchain") or not toolchain.get("rustc") or not toolchain.get("cargo") or not toolchain.get("zig"):
    errors.append("setup toolchain identity is incomplete")
if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(66)
PY
}
verify_setup_identity
setup_rust_toolchain="$(python3 - "$setup_identity_path" <<'PY'
import json
import pathlib
import sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(record["toolchain"]["rust_toolchain"])
PY
)"
setup_rustc="$(python3 - "$setup_identity_path" <<'PY'
import json
import pathlib
import sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(record["toolchain"]["rustc"])
PY
)"
setup_cargo="$(python3 - "$setup_identity_path" <<'PY'
import json
import pathlib
import sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(record["toolchain"]["cargo"])
PY
)"
setup_zig="$(python3 - "$setup_identity_path" <<'PY'
import json
import pathlib
import sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(record["toolchain"]["zig"])
PY
)"

hydrated_source_sha="$(python3 - "$setup_identity_path" <<'PY'
import json
import pathlib
import sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(record["source"]["commit_sha"])
PY
)"
hydrated_source_ref="$(python3 - "$setup_identity_path" <<'PY'
import json
import pathlib
import sys
record=json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(record["source"]["ref"])
PY
)"

benchmark_dir="$repo_root/testbox-benchmark"
command -v flock >/dev/null || {
  echo "flock is required for serialized Testbox stages" >&2
  exit 65
}
mkdir -p "$benchmark_dir"
# Testbox can acknowledge a run while its remote shell is still flushing
# output. Serialize stages and hold the lock through all artifact writes so a
# subsequent run cannot overwrite a prior stage's timing file.
exec 9>"$benchmark_dir/.stage.lock"
flock -x 9

log_path="$benchmark_dir/$stage.log"
time_path="$benchmark_dir/$stage.time"
json_path="$benchmark_dir/$stage.json"
pre_identity_path="$benchmark_dir/.$stage.pre-identity.json"
post_identity_path="$benchmark_dir/.$stage.post-identity.json"
changed_file="cmux-tui/crates/cmux-tui/src/main.rs"
changed_backup=""
changed_backup_sha256=""
changed_backup_size=""

restore_changed_file() {
  if [[ -n "$changed_backup" ]]; then
    if [[ ! -f "$changed_backup" ]]; then
      echo "changed-file backup disappeared: $changed_backup" >&2
      return 1
    fi
    if [[ "$(wc -c <"$changed_backup")" != "$changed_backup_size" ||
          "$(sha256sum "$changed_backup" | cut -d ' ' -f 1)" != "$changed_backup_sha256" ]]; then
      echo "changed-file backup failed integrity verification" >&2
      return 1
    fi
    if ! cp "$changed_backup" "$repo_root/$changed_file"; then
      return 1
    fi
    if [[ "$(wc -c <"$repo_root/$changed_file")" != "$changed_backup_size" ||
          "$(sha256sum "$repo_root/$changed_file" | cut -d ' ' -f 1)" != "$changed_backup_sha256" ]]; then
      echo "restored source failed integrity verification" >&2
      return 1
    fi
    if ! rm -f "$changed_backup"; then
      return 1
    fi
    changed_backup=""
  fi
}

# Always restore the deliberately changed source, including when Cargo exits
# non-zero. Do not let cleanup replace the build result unless restoration
# itself fails.
# SC2317 is what shellcheck 0.9 (Ubuntu 24.04) calls this; SC2329 is the 0.10+ name.
# shellcheck disable=SC2317,SC2329 # invoked indirectly by the signal/EXIT traps
finish_source() {
  local result=$?
  if [[ -n "$changed_backup" ]]; then
    if ! restore_changed_file; then
      echo "failed to restore $changed_file" >&2
      (( result == 0 )) && result=67
    fi
  fi
  exit "$result"
}
# Signals must remain failures even when they arrive after a successful command.
# The EXIT trap performs the actual restoration exactly once.
# shellcheck disable=SC2317,SC2329 # invoked indirectly by signal traps
interrupt_source() {
  local signal_name="$1"
  trap - TERM INT HUP
  case "$signal_name" in
    TERM) exit 143 ;;
    INT) exit 130 ;;
    HUP) exit 129 ;;
  esac
}
trap 'interrupt_source TERM' TERM
trap 'interrupt_source INT' INT
trap 'interrupt_source HUP' HUP
trap finish_source EXIT

clean_status() {
  local top_status ghostty_status
  top_status="$(git status --porcelain=v1 --untracked-files=normal)"
  if [[ -n "$top_status" ]]; then
    printf '%s\n' "top-level source is dirty:" "$top_status" >&2
    return 1
  fi
  ghostty_status="$(git -C ghostty status --porcelain=v1 --untracked-files=normal)"
  if [[ -n "$ghostty_status" ]]; then
    printf '%s\n' "Ghostty submodule is dirty:" "$ghostty_status" >&2
    return 1
  fi
}

capture_identity() {
  python3 - "$expected_source_sha" "$expected_tree_sha" "$expected_ghostty_sha" "$testbox_id" "$repo_root" <<'PY'
import json
import os
import pathlib
import platform
import subprocess
import sys

expected_source_sha, expected_tree_sha, expected_ghostty_sha, testbox_id, repo_root = sys.argv[1:]
repo = pathlib.Path(repo_root)
ghostty = repo / "ghostty"

def run(command, cwd=repo):
    return subprocess.check_output(command, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()

def optional_file(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return None

def status(cwd=repo):
    return subprocess.check_output(
        ["git", "status", "--porcelain=v1", "--untracked-files=normal"],
        cwd=cwd,
        text=True,
    ).splitlines()

source_sha = run(["git", "rev-parse", "HEAD"])
source_tree_sha = run(["git", "rev-parse", "HEAD^{tree}"])
ghostty_gitlink_sha = run(["git", "rev-parse", "HEAD:ghostty"])
ghostty_head_sha = run(["git", "-C", "ghostty", "rev-parse", "HEAD"])
record = {
    "commit_sha": source_sha,
    "tree_sha": source_tree_sha,
    "expected_commit_sha": expected_source_sha,
    "expected_tree_sha": expected_tree_sha,
    "dirty_files": status(),
    "ghostty": {
        "gitlink_sha": ghostty_gitlink_sha,
        "expected_gitlink_sha": expected_ghostty_sha,
        "head_sha": ghostty_head_sha,
        "dirty_files": status(ghostty),
    },
    "testbox_id": testbox_id,
    "testbox_state": {
        "adopted_run_id": optional_file(pathlib.Path("/tmp/.testbox/adopted_run_id")),
        "runner_host": optional_file(pathlib.Path("/tmp/.testbox/runner_host")),
        "runner_ssh_port": optional_file(pathlib.Path("/tmp/.testbox/runner_ssh_port")),
    },
}
print(json.dumps(record, sort_keys=True))
PY
}

verify_identity() {
  local identity_path="$1"
  python3 - "$identity_path" "$expected_source_sha" "$expected_tree_sha" "$expected_ghostty_sha" "$testbox_id" <<'PY'
import json
import pathlib
import sys

path, expected_source_sha, expected_tree_sha, expected_ghostty_sha, expected_testbox_id = sys.argv[1:]
record = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
errors = []
if record.get("commit_sha") != expected_source_sha:
    errors.append(f"source commit {record.get('commit_sha')} != {expected_source_sha}")
if record.get("expected_commit_sha") != expected_source_sha:
    errors.append("source expectation was not recorded")
if record.get("tree_sha") != expected_tree_sha:
    errors.append(f"source tree {record.get('tree_sha')} != {expected_tree_sha}")
if record.get("expected_tree_sha") != expected_tree_sha:
    errors.append("source tree expectation was not recorded")
if record.get("dirty_files"):
    errors.append("top-level source is dirty")
ghostty = record.get("ghostty", {})
if ghostty.get("gitlink_sha") != expected_ghostty_sha:
    errors.append(f"Ghostty gitlink {ghostty.get('gitlink_sha')} != {expected_ghostty_sha}")
if ghostty.get("expected_gitlink_sha") != expected_ghostty_sha:
    errors.append("Ghostty expectation was not recorded")
if ghostty.get("head_sha") != expected_ghostty_sha:
    errors.append(f"Ghostty checkout {ghostty.get('head_sha')} != {expected_ghostty_sha}")
if ghostty.get("dirty_files"):
    errors.append("Ghostty submodule is dirty")
if record.get("testbox_id") != expected_testbox_id:
    errors.append("Testbox identity mismatch")
if errors:
    for error in errors:
        print(f"source guard: {error}", file=sys.stderr)
    raise SystemExit(66)
PY
}

# Verify the immutable source and submodule before every stage. The changed-file
# stage is allowed to become dirty only after this check and must be clean again
# before its JSON record is emitted.
clean_status
capture_identity >"$pre_identity_path"
verify_identity "$pre_identity_path"

runner_label="blacksmith-32vcpu-ubuntu-2404"
zig_bin="${CMUX_ZIG:-$(command -v zig)}"
pushd cmux-tui >/dev/null
rust_toolchain="$(rustup show active-toolchain)"
rustc_version="$(rustc --version)"
cargo_version="$(cargo --version)"
popd >/dev/null
zig_version="$("$zig_bin" version)"
[[ "$rust_toolchain" == "$setup_rust_toolchain" && "$rustc_version" == "$setup_rustc" && "$cargo_version" == "$setup_cargo" && "$zig_version" == "$setup_zig" ]] || {
  echo "active Rust/Cargo/Zig toolchain differs from the setup identity marker" >&2
  exit 66
}
export ZIG="$zig_bin"
rust_toolchain_file_sha256="$(sha256sum cmux-tui/rust-toolchain.toml | cut -d ' ' -f 1)"
cargo_lock_sha256="$(sha256sum cmux-tui/Cargo.lock | cut -d ' ' -f 1)"
ghostty_zon_sha256="$(sha256sum ghostty/build.zig.zon | cut -d ' ' -f 1)"

case "$stage" in
  first-clean)
    rm -rf "$repo_root/cmux-tui/target"
    ;;
  changed-file)
    if [[ ! -f "$repo_root/$changed_file" ]]; then
      echo "changed-file target is missing: $changed_file" >&2
      exit 65
    fi
    backup_candidate="$(mktemp "${TMPDIR:-/tmp}/cmux-tui-testbox-source.XXXXXX")"
    if ! cp "$repo_root/$changed_file" "$backup_candidate"; then
      rm -f "$backup_candidate"
      echo "failed to create a source backup" >&2
      exit 67
    fi
    backup_sha256="$(sha256sum "$backup_candidate" | cut -d ' ' -f 1)"
    backup_size="$(wc -c <"$backup_candidate" | tr -d '[:space:]')"
    [[ "$backup_size" =~ ^[0-9]+$ && "$backup_size" -gt 0 ]] || {
      rm -f "$backup_candidate"
      echo "source backup is empty" >&2
      exit 67
    }
    changed_backup="$backup_candidate"
    changed_backup_sha256="$backup_sha256"
    changed_backup_size="$backup_size"
    printf '\n// Blacksmith Testbox changed-file timing marker.\n' >>"$repo_root/$changed_file"
    ;;
esac

start_epoch="$(python3 -c 'import time; print(time.time())')"
rm -f "$time_path" "$log_path" "$json_path" "$post_identity_path"
set +e
(
  cd "$repo_root/cmux-tui"
  timeout --kill-after=30s 20m \
    /usr/bin/time -p -o "$time_path" cargo build -p cmux-tui --locked
) >"$log_path" 2>&1
build_status=$?
set -e
end_epoch="$(python3 -c 'import time; print(time.time())')"

# A zero exit proves cargo was happy, not that anything was produced. Record the
# artifact so the evidence pack shows a binary existed on the box, which cannot
# be checked after the box is destroyed.
binary_path="$repo_root/cmux-tui/target/debug/cmux-tui"
binary_bytes=""
if (( build_status == 0 )); then
  if [[ -x "$binary_path" ]]; then
    binary_bytes="$(wc -c <"$binary_path" | tr -d ' ')"
  else
    echo "cargo exited 0 but $binary_path is missing or not executable" >&2
    build_status=70
  fi
fi

restore_status=0
if ! restore_changed_file; then
  echo "failed to restore $changed_file" >&2
  restore_status=67
fi

post_identity_status=0
if ! capture_identity >"$post_identity_path"; then
  echo "failed to capture post-stage source identity" >&2
  post_identity_status=66
  printf '{}\n' >"$post_identity_path"
fi
if (( post_identity_status == 0 )); then
  if ! verify_identity "$post_identity_path"; then
    post_identity_status=66
  fi
fi

if (( restore_status != 0 )); then
  final_status="$restore_status"
elif (( post_identity_status != 0 )); then
  final_status="$post_identity_status"
else
  final_status="$build_status"
fi

python3 - "$stage" "$start_epoch" "$end_epoch" "$build_status" "$final_status" "$time_path" "$pre_identity_path" "$post_identity_path" "$changed_file" "$expected_source_sha" "$expected_tree_sha" "$expected_ghostty_sha" "$testbox_id" "$runner_label" "$rust_toolchain" "$rustc_version" "$cargo_version" "$zig_bin" "$zig_version" "$rust_toolchain_file_sha256" "$cargo_lock_sha256" "$ghostty_zon_sha256" "$hydrated_source_ref" "$hydrated_source_sha" "$binary_bytes" >"$json_path" <<'PY'
import datetime as dt
import json
import os
import pathlib
import platform
import sys

(
    stage,
    start,
    end,
    build_status,
    final_status,
    time_path,
    pre_identity_path,
    post_identity_path,
    changed_file,
    expected_source_sha,
    expected_tree_sha,
    expected_ghostty_sha,
    testbox_id,
    runner_label,
    rust_toolchain,
    rustc_version,
    cargo_version,
    zig_bin,
    zig_version,
    rust_toolchain_file_sha256,
    cargo_lock_sha256,
    ghostty_zon_sha256,
    hydrated_source_ref,
    hydrated_source_sha,
    binary_bytes,
) = sys.argv[1:]

def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}

remote_time = {}
try:
    for line in pathlib.Path(time_path).read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition(" ")
        if key in {"real", "user", "sys"}:
            remote_time[f"time_{key}_seconds"] = float(value)
except OSError:
    pass

pre = read_json(pre_identity_path)
post = read_json(post_identity_path)
record = {
    "schema": 3,
    "stage": stage,
    "command": "cargo build -p cmux-tui --locked",
    # Proof the build produced something, since the box is destroyed afterwards.
    "artifact": {
        "path": "cmux-tui/target/debug/cmux-tui",
        "size_bytes": int(binary_bytes) if binary_bytes else None,
    },
    "build_exit_code": int(build_status),
    "exit_code": int(final_status),
    "ok": int(final_status) == 0,
    "started_at": dt.datetime.fromtimestamp(float(start), dt.timezone.utc).isoformat(),
    "finished_at": dt.datetime.fromtimestamp(float(end), dt.timezone.utc).isoformat(),
    "wall_seconds": round(float(end) - float(start), 3),
    "source": {
        "expected_commit_sha": expected_source_sha,
        "expected_tree_sha": expected_tree_sha,
        "before": pre,
        "after": post,
        "changed_file": changed_file if stage == "changed-file" else None,
        "restored": stage != "changed-file" or not post.get("dirty_files"),
    },
    "ghostty": {
        "expected_gitlink_sha": expected_ghostty_sha,
        "before_gitlink_sha": pre.get("ghostty", {}).get("gitlink_sha"),
        "before_head_sha": pre.get("ghostty", {}).get("head_sha"),
        "after_gitlink_sha": post.get("ghostty", {}).get("gitlink_sha"),
        "after_head_sha": post.get("ghostty", {}).get("head_sha"),
    },
    "testbox": {
        "id": testbox_id,
        "adopted_run_id": pre.get("testbox_state", {}).get("adopted_run_id"),
    },
    # What the broker warmed the caches from. It is main, and it is normally a
    # different commit from the benchmarked revision above.
    "hydration": {
        "ref": hydrated_source_ref,
        "commit_sha": hydrated_source_sha,
        "matches_benchmarked_source": hydrated_source_sha == expected_source_sha,
    },
    "runner": {
        "label": runner_label,
        "hostname": platform.node(),
        "arch": platform.machine(),
        "cpu_count": os.cpu_count(),
        "uname": " ".join(platform.uname()),
        "host_from_testbox_state": pre.get("testbox_state", {}).get("runner_host"),
    },
    "toolchain": {
        "rust_toolchain": rust_toolchain,
        "rustc": rustc_version,
        "cargo": cargo_version,
        "rust_toolchain_file_sha256": rust_toolchain_file_sha256,
        "cargo_lock_sha256": cargo_lock_sha256,
        "zig_path": zig_bin,
        "zig": zig_version,
        "ghostty_build_zig_zon_sha256": ghostty_zon_sha256,
    },
    **remote_time,
}
print(json.dumps(record, sort_keys=True))
PY

cat "$log_path"
printf '\n--- /usr/bin/time -p (%s) ---\n' "$stage"
if [[ -f "$time_path" ]]; then
  cat "$time_path"
else
  echo "time output unavailable" >&2
fi
printf '\n--- structured timing (%s) ---\n' "$stage"
cat "$json_path"
exit "$final_status"
