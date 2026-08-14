#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# This file is checked out from the protected broker commit. The workflow uses
# prepare and hydrate. Hydrate installs the same trusted file outside the CLI
# sync root as the fixed-SHA warm-build entrypoint.

die() {
  echo "::error::$*" >&2
  exit 1
}

usage() {
  echo "usage: $0 {prepare|hydrate} <candidate-source>" >&2
  echo "       CMUX_TESTBOX_REMOTE=1 CMUX_TESTBOX_ID=tbx_... /tmp/.testbox/cmux-tui-rust-warm-build <source-sha>" >&2
  exit 2
}

require_sha() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || die "$name is not a full lowercase SHA"
}

state_dir=/tmp/.testbox
runtime_parent=/tmp/cmux-testbox-broker
expected_testbox_id="${TESTBOX_ID:-${CMUX_TESTBOX_ID:-}}"
runtime_root=
state_run_id=

read_state() {
  local name="$1"
  local path="$state_dir/$name"
  [[ -f "$path" && ! -L "$path" ]] || die "missing Testbox registration state file: $name"
  local value
  value="$(<"$path")"
  [[ -n "$value" ]] || die "empty Testbox registration state file: $name"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "unsafe newline in Testbox registration state: $name"
  printf '%s' "$value"
}

require_testbox_state() {
  [[ -d "$state_dir" && ! -L "$state_dir" ]] || die "Testbox registration state is absent"
  local state_mode
  state_mode="$(stat -c '%a' "$state_dir")"
  [[ "$state_mode" == "700" ]] || die "Testbox registration state directory is not private"
  [[ "$expected_testbox_id" =~ ^tbx_[A-Za-z0-9_-]+$ ]] || die "expected Testbox ID is malformed"

  local state_testbox_id
  state_testbox_id="$(read_state testbox_id)"
  [[ "$state_testbox_id" == "$expected_testbox_id" ]] || die "Testbox registration state has a different ID"
  state_run_id="$(read_state adopted_run_id)"
  [[ "$state_run_id" =~ ^[0-9]+$ ]] || die "Testbox adopted run ID is malformed"
  if [[ -n "${GITHUB_RUN_ID:-}" && "$state_run_id" != "$GITHUB_RUN_ID" ]]; then
    die "Testbox registration belongs to a different workflow run"
  fi
  runtime_root="$runtime_parent/$expected_testbox_id"
}

candidate_sha=
candidate_tree_sha=
ghostty_gitlink_sha=
ghostty_head_sha=

capture_candidate_identity() {
  local candidate_root="$1"
  [[ -f "$candidate_root/cmux-tui/Cargo.toml" ]] || die "candidate cmux-tui manifest is missing"
  [[ -f "$candidate_root/cmux-tui/Cargo.lock" ]] || die "candidate Cargo lock file is missing"
  [[ -f "$candidate_root/cmux-tui/rust-toolchain.toml" ]] || die "candidate Rust toolchain file is missing"
  [[ -f "$candidate_root/ghostty/build.zig.zon" ]] || die "candidate Ghostty source is not initialized"

  local candidate_git_root
  candidate_git_root="$(git -C "$candidate_root" rev-parse --show-toplevel 2>/dev/null)" || die "candidate is not a Git checkout"
  [[ "$candidate_git_root" == "$candidate_root" ]] || die "candidate Git root is not the expected directory"
  candidate_sha="$(git -C "$candidate_root" rev-parse --verify HEAD)"
  candidate_tree_sha="$(git -C "$candidate_root" rev-parse 'HEAD^{tree}')"
  local ghostty_entry
  ghostty_entry="$(git -C "$candidate_root" ls-tree HEAD ghostty)"
  [[ "$ghostty_entry" =~ ^160000[[:space:]]commit[[:space:]][0-9a-f]{40}[[:space:]]ghostty$ ]] || {
    die "candidate HEAD:ghostty is not a gitlink"
  }
  ghostty_gitlink_sha="$(git -C "$candidate_root" rev-parse HEAD:ghostty)"
  local ghostty_root
  ghostty_root="$(git -C "$candidate_root/ghostty" rev-parse --show-toplevel 2>/dev/null)" || {
    die "candidate Ghostty checkout is invalid"
  }
  [[ "$ghostty_root" == "$candidate_root/ghostty" ]] || die "candidate Ghostty root is not the expected directory"
  ghostty_head_sha="$(git -C "$candidate_root/ghostty" rev-parse --verify HEAD)"
  [[ "$ghostty_head_sha" == "$ghostty_gitlink_sha" ]] || die "candidate Ghostty checkout does not match its gitlink"
  [[ -z "$(git -C "$candidate_root" status --porcelain=v1 --untracked-files=normal)" ]] || {
    git -C "$candidate_root" status --short >&2
    die "candidate source is dirty"
  }
  [[ -z "$(git -C "$candidate_root/ghostty" status --porcelain=v1 --untracked-files=normal)" ]] || {
    git -C "$candidate_root/ghostty" status --short >&2
    die "candidate Ghostty checkout is dirty"
  }
}

require_reviewed_candidate() {
  local candidate_root="$1"
  local reviewed_sha="${BLACKSMITH_TESTBOX_REVIEWED_SHA:-}"
  local reviewed_ref="${BLACKSMITH_TESTBOX_REVIEWED_REF:-}"
  require_sha BLACKSMITH_TESTBOX_REVIEWED_SHA "$reviewed_sha"
  [[ "$reviewed_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || die "protected reviewed ref is malformed"
  [[ "$reviewed_ref" != refs/* && "$reviewed_ref" != /* && "$reviewed_ref" != */ ]] || {
    die "protected reviewed ref is malformed"
  }
  [[ "$reviewed_ref" != *//* && "$reviewed_ref" != *..* && "$reviewed_ref" != -* ]] || {
    die "protected reviewed ref is malformed"
  }
  git check-ref-format --branch "$reviewed_ref" >/dev/null 2>&1 || die "protected reviewed ref is not a Git branch"
  capture_candidate_identity "$candidate_root"
  [[ "$candidate_sha" == "$reviewed_sha" ]] || die "candidate checkout does not equal the protected reviewed SHA"
}

resolve_broker_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  local broker_root
  broker_root="$(cd "$script_dir/../.." && pwd -P)"
  local broker_sha="${BLACKSMITH_TESTBOX_BROKER_SHA:-}"
  require_sha BLACKSMITH_TESTBOX_BROKER_SHA "$broker_sha"
  [[ "$(git -C "$broker_root" rev-parse --verify HEAD)" == "$broker_sha" ]] || {
    die "setup helper is not running from the protected broker checkout"
  }
  printf '%s' "$broker_root"
}

resolve_candidate_root() {
  local broker_root="$1"
  local supplied_path="$2"
  local workspace="${GITHUB_WORKSPACE:-$broker_root}"
  local workspace_real
  workspace_real="$(cd "$workspace" && pwd -P)" || die "GitHub workspace does not exist"
  [[ "$workspace_real" == "$broker_root" ]] || die "GitHub workspace is not the broker root"
  local candidate_root
  candidate_root="$(cd "$supplied_path" && pwd -P)" || die "candidate source path does not exist"
  [[ "$candidate_root" == "$workspace_real/candidate-source" ]] || die "candidate source is not isolated at candidate-source"
  printf '%s' "$candidate_root"
}

write_prepare_identity() {
  local path="$1"
  local broker_sha="$2"
  local reviewed_ref="$3"
  local zig_required="$4"
  SOURCE_SHA="$candidate_sha" \
  SOURCE_TREE_SHA="$candidate_tree_sha" \
  GHOSTTY_GITLINK_SHA="$ghostty_gitlink_sha" \
  GHOSTTY_HEAD_SHA="$ghostty_head_sha" \
  BROKER_SHA="$broker_sha" \
  REVIEWED_REF="$reviewed_ref" \
  TESTBOX_ID_VALUE="$expected_testbox_id" \
  SETUP_RUN_ID="$state_run_id" \
  ZIG_REQUIRED_VALUE="$zig_required" \
    python3 - <<'PY' >"$path"
import json
import os

print(json.dumps({
    "schema": 1,
    "broker_sha": os.environ["BROKER_SHA"],
    "source": {
        "ref": os.environ["REVIEWED_REF"],
        "commit_sha": os.environ["SOURCE_SHA"],
        "tree_sha": os.environ["SOURCE_TREE_SHA"],
        "ghostty_gitlink_sha": os.environ["GHOSTTY_GITLINK_SHA"],
        "ghostty_head_sha": os.environ["GHOSTTY_HEAD_SHA"],
    },
    "testbox": {
        "id": os.environ["TESTBOX_ID_VALUE"],
        "setup_workflow_run_id": os.environ["SETUP_RUN_ID"],
    },
    "zig_required": os.environ["ZIG_REQUIRED_VALUE"],
}, sort_keys=True, indent=2))
PY
  [[ -s "$path" ]] || die "prepare identity is empty"
}

prepare() {
  [[ $# -eq 1 ]] || usage
  require_testbox_state
  local broker_root
  broker_root="$(resolve_broker_root)"
  local candidate_root
  candidate_root="$(resolve_candidate_root "$broker_root" "$1")"
  local reviewed_sha="${BLACKSMITH_TESTBOX_REVIEWED_SHA:-}"
  local reviewed_ref="${BLACKSMITH_TESTBOX_REVIEWED_REF:-}"
  require_sha BLACKSMITH_TESTBOX_REVIEWED_SHA "$reviewed_sha"

  local pre_init_sha pre_init_tree ghostty_entry
  pre_init_sha="$(git -C "$candidate_root" rev-parse --verify HEAD)"
  pre_init_tree="$(git -C "$candidate_root" rev-parse 'HEAD^{tree}')"
  ghostty_entry="$(git -C "$candidate_root" ls-tree HEAD ghostty)"
  [[ "$pre_init_sha" == "$reviewed_sha" ]] || die "candidate checkout does not equal the protected reviewed SHA"
  [[ "$ghostty_entry" =~ ^160000[[:space:]]commit[[:space:]][0-9a-f]{40}[[:space:]]ghostty$ ]] || {
    die "candidate HEAD:ghostty is not a gitlink"
  }

  git -C "$candidate_root" submodule update --init --depth 1 ghostty
  require_reviewed_candidate "$candidate_root"
  [[ "$candidate_sha" == "$pre_init_sha" && "$candidate_tree_sha" == "$pre_init_tree" ]] || {
    die "candidate identity changed during Ghostty initialization"
  }

  cmp -s "$candidate_root/cmux-tui/rust-toolchain.toml" "$broker_root/cmux-tui/rust-toolchain.toml" || {
    die "candidate Rust pin differs from the trusted repository action pin"
  }
  local zig_required
  zig_required="$(sed -nE 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$candidate_root/ghostty/build.zig.zon" | head -1)"
  [[ "$zig_required" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "candidate Ghostty Zig version is invalid"

  [[ ! -e "$runtime_parent" && ! -L "$runtime_parent" ]] || {
    [[ -d "$runtime_parent" && ! -L "$runtime_parent" ]] || die "broker runtime parent is unsafe"
  }
  install -d -m 700 "$runtime_parent"
  [[ ! -e "$runtime_root" && ! -L "$runtime_root" ]] || die "broker runtime root already exists"
  install -d -m 700 "$runtime_root"
  write_prepare_identity \
    "$runtime_root/prepare-identity.json" \
    "${BLACKSMITH_TESTBOX_BROKER_SHA:-}" \
    "$reviewed_ref" \
    "$zig_required"
  chmod 600 "$runtime_root/prepare-identity.json"

  sudo apt-get update
  sudo apt-get install -y clang libclang-dev pkg-config

  [[ -n "${GITHUB_ENV:-}" && -f "$GITHUB_ENV" && ! -L "$GITHUB_ENV" ]] || die "GITHUB_ENV is unavailable"
  printf 'ZIG_REQUIRED=%s\n' "$zig_required" >>"$GITHUB_ENV"
  printf 'prepared reviewed source %s, tree %s, Ghostty %s\n' \
    "$candidate_sha" "$candidate_tree_sha" "$ghostty_gitlink_sha"
}

verify_prepare_identity() {
  local path="$1"
  local broker_sha="$2"
  local reviewed_ref="$3"
  local zig_required="$4"
  python3 - "$path" "$broker_sha" "$reviewed_ref" "$candidate_sha" "$candidate_tree_sha" \
    "$ghostty_gitlink_sha" "$expected_testbox_id" "$state_run_id" "$zig_required" <<'PY'
import json
import pathlib
import sys

(path, broker_sha, reviewed_ref, source_sha, tree_sha, ghostty_sha,
 testbox_id, run_id, zig_required) = sys.argv[1:]
record = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
errors = []
if record.get("broker_sha") != broker_sha:
    errors.append("broker SHA changed after prepare")
source = record.get("source", {})
for key, expected in {
    "ref": reviewed_ref,
    "commit_sha": source_sha,
    "tree_sha": tree_sha,
    "ghostty_gitlink_sha": ghostty_sha,
    "ghostty_head_sha": ghostty_sha,
}.items():
    if source.get(key) != expected:
        errors.append(f"prepared source {key} changed")
testbox = record.get("testbox", {})
if testbox.get("id") != testbox_id or str(testbox.get("setup_workflow_run_id")) != run_id:
    errors.append("prepared Testbox identity changed")
if record.get("zig_required") != zig_required:
    errors.append("prepared Zig pin changed")
if errors:
    raise SystemExit("; ".join(errors))
PY
}

write_setup_identity() {
  local output="$1"
  local broker_sha="$2"
  local reviewed_ref="$3"
  local source_root="$4"
  local zig_path="$5"
  local cargo_path="$6"
  local rustc_path="$7"
  local rustup_path="$8"
  local script_sha256="$9"

  local cargo_metadata="$RUNNER_TEMP/cmux-tui-cargo-metadata.json"
  (
    cd "$source_root/cmux-tui"
    "$cargo_path" metadata --locked --no-deps --format-version 1 >"$cargo_metadata"
  )
  [[ -s "$cargo_metadata" ]] || die "Cargo metadata is empty"

  local rust_toolchain rustc_version cargo_version zig_version
  rust_toolchain="$(cd "$source_root/cmux-tui" && "$rustup_path" show active-toolchain)"
  rustc_version="$($rustc_path --version)"
  cargo_version="$($cargo_path --version)"
  zig_version="$($zig_path version)"
  local runner_cpu_count
  runner_cpu_count="$(nproc)"
  [[ "${RUNNER_ARCH:-}" == "X64" && "$runner_cpu_count" == "32" ]] || {
    die "expected X64 32-vCPU runner, got arch=${RUNNER_ARCH:-unset} cpu_count=$runner_cpu_count"
  }

  SOURCE_SHA="$candidate_sha" \
  SOURCE_TREE_SHA="$candidate_tree_sha" \
  GHOSTTY_GITLINK_SHA="$ghostty_gitlink_sha" \
  GHOSTTY_HEAD_SHA="$ghostty_head_sha" \
  BROKER_SHA="$broker_sha" \
  REVIEWED_REF="$reviewed_ref" \
  TESTBOX_ID_VALUE="$expected_testbox_id" \
  SETUP_RUN_ID="$state_run_id" \
  RUNNER_LABEL_VALUE="blacksmith-32vcpu-ubuntu-2404" \
  RUNNER_CPU_COUNT="$runner_cpu_count" \
  RUNNER_UNAME="$(uname -a)" \
  RUST_TOOLCHAIN="$rust_toolchain" \
  RUSTC_VERSION="$rustc_version" \
  CARGO_VERSION="$cargo_version" \
  ZIG_VERSION="$zig_version" \
  ZIG_PATH="$zig_path" \
  CARGO_PATH="$cargo_path" \
  RUSTC_PATH="$rustc_path" \
  RUSTUP_PATH="$rustup_path" \
  SETUP_SCRIPT_SHA256="$script_sha256" \
  RUST_TOOLCHAIN_FILE_SHA256="$(sha256sum "$source_root/cmux-tui/rust-toolchain.toml" | cut -d ' ' -f 1)" \
  CARGO_LOCK_SHA256="$(sha256sum "$source_root/cmux-tui/Cargo.lock" | cut -d ' ' -f 1)" \
  CARGO_METADATA_SHA256="$(sha256sum "$cargo_metadata" | cut -d ' ' -f 1)" \
  GHOSTTY_ZON_SHA256="$(sha256sum "$source_root/ghostty/build.zig.zon" | cut -d ' ' -f 1)" \
    python3 - <<'PY' >"$output"
import json
import os
import platform

print(json.dumps({
    "schema": 3,
    "broker": {
        "commit_sha": os.environ["BROKER_SHA"],
        "setup_script_sha256": os.environ["SETUP_SCRIPT_SHA256"],
    },
    "source": {
        "ref": os.environ["REVIEWED_REF"],
        "commit_sha": os.environ["SOURCE_SHA"],
        "tree_sha": os.environ["SOURCE_TREE_SHA"],
        "ghostty_gitlink_sha": os.environ["GHOSTTY_GITLINK_SHA"],
        "ghostty_head_sha": os.environ["GHOSTTY_HEAD_SHA"],
    },
    "testbox": {
        "id": os.environ["TESTBOX_ID_VALUE"],
        "setup_workflow_run_id": os.environ["SETUP_RUN_ID"],
    },
    "runner": {
        "label": os.environ["RUNNER_LABEL_VALUE"],
        "name": os.environ.get("RUNNER_NAME"),
        "os": os.environ.get("RUNNER_OS"),
        "arch": os.environ.get("RUNNER_ARCH"),
        "hostname": platform.node(),
        "uname": os.environ["RUNNER_UNAME"],
        "cpu_count": int(os.environ["RUNNER_CPU_COUNT"]),
    },
    "toolchain": {
        "rust_toolchain": os.environ["RUST_TOOLCHAIN"],
        "rustc": os.environ["RUSTC_VERSION"],
        "cargo": os.environ["CARGO_VERSION"],
        "zig": os.environ["ZIG_VERSION"],
        "zig_path": os.environ["ZIG_PATH"],
        "cargo_path": os.environ["CARGO_PATH"],
        "rustc_path": os.environ["RUSTC_PATH"],
        "rustup_path": os.environ["RUSTUP_PATH"],
        "rust_toolchain_file_sha256": os.environ["RUST_TOOLCHAIN_FILE_SHA256"],
        "cargo_lock_sha256": os.environ["CARGO_LOCK_SHA256"],
        "cargo_metadata_sha256": os.environ["CARGO_METADATA_SHA256"],
        "ghostty_build_zig_zon_sha256": os.environ["GHOSTTY_ZON_SHA256"],
    },
}, sort_keys=True, indent=2))
PY
  [[ -s "$output" ]] || die "setup identity is empty"
}

hydrate() {
  [[ $# -eq 1 ]] || usage
  require_testbox_state
  local broker_root
  broker_root="$(resolve_broker_root)"
  local candidate_root
  candidate_root="$(resolve_candidate_root "$broker_root" "$1")"
  require_reviewed_candidate "$candidate_root"
  local broker_sha="${BLACKSMITH_TESTBOX_BROKER_SHA:-}"
  local reviewed_ref="${BLACKSMITH_TESTBOX_REVIEWED_REF:-}"
  local prepare_identity="$runtime_root/prepare-identity.json"
  [[ -f "$prepare_identity" && ! -L "$prepare_identity" ]] || die "prepare identity is missing"

  local zig_required
  zig_required="$(sed -nE 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$candidate_root/ghostty/build.zig.zon" | head -1)"
  verify_prepare_identity "$prepare_identity" "$broker_sha" "$reviewed_ref" "$zig_required"
  cmp -s "$candidate_root/cmux-tui/rust-toolchain.toml" "$broker_root/cmux-tui/rust-toolchain.toml" || {
    die "candidate Rust pin differs from the trusted repository action pin"
  }

  local zig_path="${CMUX_ZIG:-}"
  [[ "$zig_path" == /* && -x "$zig_path" ]] || die "repository-pinned Zig is unavailable"
  [[ "$($zig_path version)" == "$zig_required" ]] || die "active Zig version differs from the candidate pin"
  local cargo_path rustc_path rustup_path
  cargo_path="$(command -v cargo)" || die "repository-pinned Cargo is unavailable"
  rustc_path="$(command -v rustc)" || die "repository-pinned rustc is unavailable"
  rustup_path="$(command -v rustup)" || die "rustup is unavailable"

  (
    cd "$candidate_root/ghostty"
    "$zig_path" build --fetch
  )
  (
    cd "$candidate_root/cmux-tui"
    "$cargo_path" fetch --locked
  )
  capture_candidate_identity "$candidate_root"
  [[ "$candidate_sha" == "${BLACKSMITH_TESTBOX_REVIEWED_SHA:-}" ]] || die "candidate changed during hydration"

  local source_root="$runtime_root/source"
  [[ ! -e "$source_root" && ! -L "$source_root" ]] || die "broker source root already exists"
  mv "$candidate_root" "$source_root"
  capture_candidate_identity "$source_root"
  [[ "$candidate_sha" == "${BLACKSMITH_TESTBOX_REVIEWED_SHA:-}" ]] || die "candidate changed while it moved outside the sync root"

  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  local script_sha256
  script_sha256="$(sha256sum "$script_path" | cut -d ' ' -f 1)"
  local setup_identity="$RUNNER_TEMP/cmux-tui-rust-setup-identity.json"
  write_setup_identity "$setup_identity" "$broker_sha" "$reviewed_ref" "$source_root" \
    "$zig_path" "$cargo_path" "$rustc_path" "$rustup_path" "$script_sha256"

  local marker="$state_dir/cmux-tui-rust-setup-identity.json"
  local entrypoint="$state_dir/cmux-tui-rust-warm-build"
  [[ ! -e "$marker" && ! -L "$marker" ]] || die "setup identity marker already exists"
  [[ ! -e "$entrypoint" && ! -L "$entrypoint" ]] || die "warm-build entrypoint already exists"
  install -m 600 "$setup_identity" "$marker"
  install -m 700 "$script_path" "$entrypoint"
  install -m 600 "$setup_identity" "$runtime_root/setup-identity.json"
  printf 'hydrated reviewed source %s; warm build entrypoint: %s\n' "$candidate_sha" "$entrypoint"
}

json_value() {
  local path="$1"
  local section="$2"
  local key="$3"
  python3 - "$path" "$section" "$key" <<'PY'
import json
import pathlib
import sys

path, section, key = sys.argv[1:]
value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))[section][key]
if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
    raise SystemExit(f"invalid identity value: {section}.{key}")
print(value)
PY
}

verify_warm_identity() {
  local identity="$1"
  local expected_sha="$2"
  local script_sha256="$3"
  local rust_toolchain="$4"
  local rustc_version="$5"
  local cargo_version="$6"
  local zig_version="$7"
  local source_root="$8"
  python3 - "$identity" "$expected_sha" "$expected_testbox_id" "$state_run_id" "$script_sha256" \
    "$rust_toolchain" "$rustc_version" "$cargo_version" "$zig_version" \
    "$(git -C "$source_root" rev-parse HEAD)" \
    "$(git -C "$source_root" rev-parse 'HEAD^{tree}')" \
    "$(git -C "$source_root" rev-parse HEAD:ghostty)" \
    "$(git -C "$source_root/ghostty" rev-parse HEAD)" \
    "$(sha256sum "$source_root/cmux-tui/rust-toolchain.toml" | cut -d ' ' -f 1)" \
    "$(sha256sum "$source_root/cmux-tui/Cargo.lock" | cut -d ' ' -f 1)" \
    "$(sha256sum "$source_root/ghostty/build.zig.zon" | cut -d ' ' -f 1)" <<'PY'
import json
import pathlib
import sys

(path, expected_sha, testbox_id, run_id, script_sha256, rust_toolchain,
 rustc_version, cargo_version, zig_version, source_sha, tree_sha,
 ghostty_gitlink, ghostty_head, rust_file_sha, cargo_lock_sha,
 ghostty_zon_sha) = sys.argv[1:]
record = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
checks = {
    "broker setup script": (record.get("broker", {}).get("setup_script_sha256"), script_sha256),
    "source commit": (record.get("source", {}).get("commit_sha"), expected_sha),
    "source checkout": (source_sha, expected_sha),
    "source tree": (tree_sha, record.get("source", {}).get("tree_sha")),
    "Ghostty gitlink": (ghostty_gitlink, record.get("source", {}).get("ghostty_gitlink_sha")),
    "Ghostty checkout": (ghostty_head, record.get("source", {}).get("ghostty_head_sha")),
    "Testbox ID": (record.get("testbox", {}).get("id"), testbox_id),
    "setup run ID": (str(record.get("testbox", {}).get("setup_workflow_run_id")), run_id),
    "Rust toolchain": (rust_toolchain, record.get("toolchain", {}).get("rust_toolchain")),
    "rustc": (rustc_version, record.get("toolchain", {}).get("rustc")),
    "Cargo": (cargo_version, record.get("toolchain", {}).get("cargo")),
    "Zig": (zig_version, record.get("toolchain", {}).get("zig")),
    "Rust pin": (rust_file_sha, record.get("toolchain", {}).get("rust_toolchain_file_sha256")),
    "Cargo lock": (cargo_lock_sha, record.get("toolchain", {}).get("cargo_lock_sha256")),
    "Ghostty Zig manifest": (ghostty_zon_sha, record.get("toolchain", {}).get("ghostty_build_zig_zon_sha256")),
}
errors = [name for name, (actual, expected) in checks.items() if actual != expected]
if errors:
    raise SystemExit("warm-build identity mismatch: " + ", ".join(errors))
PY
}

warm_build() {
  [[ $# -eq 1 ]] || usage
  [[ "${CMUX_TESTBOX_REMOTE:-}" == "1" ]] || die "warm build requires CMUX_TESTBOX_REMOTE=1"
  if [[ ! -r /proc/cmdline ]] || ! grep -Eq '(^|[[:space:]])metadata_port=[^[:space:]]+' /proc/cmdline; then
    die "warm build requires the Blacksmith Testbox metadata marker"
  fi
  local expected_sha="$1"
  require_sha source_sha "$expected_sha"
  require_testbox_state
  command -v flock >/dev/null || die "flock is required for serialized warm builds"
  command -v timeout >/dev/null || die "timeout is required for bounded warm builds"
  [[ -d "$runtime_root" && ! -L "$runtime_root" ]] || die "broker runtime root is unavailable"
  local source_root="$runtime_root/source"
  local identity="$state_dir/cmux-tui-rust-setup-identity.json"
  [[ -f "$identity" && ! -L "$identity" ]] || die "setup identity marker is unavailable"

  exec 9>"$runtime_root/build.lock"
  flock -x 9
  capture_candidate_identity "$source_root"

  local zig_path cargo_path rustc_path rustup_path
  zig_path="$(json_value "$identity" toolchain zig_path)"
  cargo_path="$(json_value "$identity" toolchain cargo_path)"
  rustc_path="$(json_value "$identity" toolchain rustc_path)"
  rustup_path="$(json_value "$identity" toolchain rustup_path)"
  for tool_path in "$zig_path" "$cargo_path" "$rustc_path" "$rustup_path"; do
    [[ "$tool_path" == /* && -x "$tool_path" ]] || die "recorded tool path is unavailable: $tool_path"
  done

  local rust_toolchain rustc_version cargo_version zig_version script_sha256
  rust_toolchain="$(cd "$source_root/cmux-tui" && "$rustup_path" show active-toolchain)"
  rustc_version="$($rustc_path --version)"
  cargo_version="$($cargo_path --version)"
  zig_version="$($zig_path version)"
  script_sha256="$(sha256sum "${BASH_SOURCE[0]}" | cut -d ' ' -f 1)"
  verify_warm_identity "$identity" "$expected_sha" "$script_sha256" "$rust_toolchain" \
    "$rustc_version" "$cargo_version" "$zig_version" "$source_root"

  export ZIG="$zig_path"
  export CMUX_ZIG="$zig_path"
  (
    cd "$source_root/cmux-tui"
    timeout --kill-after=30s 20m "$cargo_path" build -p cmux-tui --locked
  )
  capture_candidate_identity "$source_root"
  [[ "$candidate_sha" == "$expected_sha" ]] || die "source changed during warm build"
}

if [[ "$(basename "$0")" == "cmux-tui-rust-warm-build" ]]; then
  warm_build "$@"
  exit 0
fi

[[ $# -ge 1 ]] || usage
mode="$1"
shift
case "$mode" in
  prepare) prepare "$@" ;;
  hydrate) hydrate "$@" ;;
  *) usage ;;
esac
