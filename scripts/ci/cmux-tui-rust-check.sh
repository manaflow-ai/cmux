#!/usr/bin/env bash
# cmux-tui's Rust checks on a fleet host, as a cmux-ci step:
#   cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --key KEY \
#     --os linux|macos --arg MODE [--arg TEST_FILTER]
# --os: fmt, clippy, test, all, terminal, api-compat and panic go to Blacksmith Linux first (as
# cmux-tui.yml gates them) unless the step asks for macOS; a test behind cfg(target_os = "macos")
# needs --os macos, or it runs nothing on Linux. The other modes run on macOS only.
# MODE: fmt (cargo fmt --check), clippy (-D warnings), test [FILTER] (cargo nextest, a
# failed test reruns once alone: see workspace_tests), or all [FILTER];
# panic: the "Rust panic ratchet" step of cmux-tui.yml's Linux lint job, the same two commands
# (cargo clippy --lib --bins with rust_panic_ratchet.py --flags, then rust_panic_ratchet.py
# --clippy-json; plans/cmux-next/rust-panic-free.md), so a merge batch or train can judge its tree
# against scripts/cmux-next/rust-panic-baseline.json before it lands. Linux only: the baseline holds
# Linux counts, and on macOS clippy also sees the macOS-only code and misses the Linux-only code (a
# false red or a false green), so off Linux it refuses (exit 2, no cargo). No TEST_FILTER. The clippy
# JSON is .build/artifacts/panic-clippy.jsonl, which the workflow uploads; a fleet step fetches it with
# `--os linux --artifact .build/artifacts/panic-clippy.jsonl` (the Linux route returns that one file, hq#5957),
# and a failed clippy also prints its errors;
# optchat-chief [FILTER]: tests, clippy -D warnings and fmt --check of
# Native/OptChat/optchat-chief (its own workspace and lockfile), tests first so
# a red run still reports them; without --locked, so a new dependency resolves
# into its Cargo.lock (return it with --artifact Native/OptChat/optchat-chief/Cargo.lock);
# rd-host: clippy and tests of cmux-tui/crates/cmux-rd-host (its own workspace, so the
# modes above never build it) on macOS, including its VideoToolbox path, without x264
# (no libx264 on the fleet) and with the bench feature (OpenH264 from source).
# rd-bench: a release build of cmux-rd-host's bench client (no x264, OpenH264 from source)
# at .build/artifacts/cmux-rd (macOS arm64; fetch it with --artifact), so a developer
# Mac can measure a remote host (the cloud browser VM) without building cargo locally.
# rb-testhost: fmt, clippy and tests of cmux-tui/crates/cmux-remote-browser-testhost
# (its own workspace), then its release binary at .build/artifacts/cmux-remote-browser-testhost
# (macOS arm64; fetch it with --artifact) for the remote tab's GUI proofs.
# vm-cli: clippy and tests of the cmux VM API operator CLI (workers/cmux-vm/cli, its own
# workspace and lockfile), then its release binary at .build/artifacts/cmux-vm (macOS arm64;
# fetch it with --artifact) to drive a preview or staging cmux VM API from a developer Mac.
# screen: clippy and tests of cmux-screen (its own workspace: the WebRTC screen host and
# cmux-tailnet, which links libtailscale built with Go; a pinned Go 1.27.1 is fetched into
# .build/go-1.27.1 when the host has none), then a release build of both binaries. No fmt
# step: the imported host code predates a cmux-screen rustfmt config.
# optchat-chief: fmt, clippy and tests of Native/OptChat/optchat-chief (its own workspace)
# on macOS, where the Chief host runs: its macOS-only code (the acpmux socket peer check,
# cx-ggai: LOCAL_PEERPID, proc_pidpath, the Security framework) runs only here.
# The fleet may run cargo through cmux-ci (coordinator, 2026-10-04); a developer
# Mac never runs it (the laptop and the minis by hand stay off limits), so
# outside a step (CMUX_CI_STEP_KEY) it refuses. The target dir is the step's
# own (.build/cmux-tui-rust-target in its checkout), and files are created
# with umask 022. A fleet worker may run the step in a warm checkout (HQ
# build-fleet step_warm.go, cargo pool: one step at a time per slot, at one
# path, reset to the exact commit except .build), so the target can hold the
# last step's build; cargo's fingerprints decide what is rebuilt, and
# warm_target_guard wipes it when the toolchain or its stamp changes.
# terminal [FILTER]: the tests of the terminal stack's crates only (terminal_crates:
# ghostty-vt with its VT, tmux regress, kitty graphics and corpus suites, ghostty-vt-sys,
# the PTY, sizing, encode and client crates), no fmt, clippy or doc tests: the fast
# gate for a terminal change (cmux-next-terminal.yml).
# api-compat: cmux-tui-spec.yml's api-compat job, the same command (`cargo run --locked
# -p cmux-api-compat --bin api-compat-check`): a protocol change that can break an older
# or newer peer needs a compat rule, and spec/api-compat.surface.json must be current.
# api-compat-write: the same with --write (it refuses while a break lacks a rule), which
# rewrites the snapshot cmux-tui/spec/api-compat.surface.json and, where the crate has the
# wire ledger, cmux-tui/spec/api-compat.wire.json. The step packs every api-compat file
# --write may write into .build/artifacts/api-compat-spec.tar (never empty) and prints the
# diff stat; fetch it with --artifact, run `tar -xf FILE` at your checkout root and commit
# what changed there. Neither
# takes a TEST_FILTER or checks out ghostty-next (cmux-api-compat's Cargo.lock closure has
# no Ghostty crate: tests/test_zig_free_step_lockfiles.py), and neither commits or pushes.
set -euo pipefail
if [[ -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  cat >&2 <<'MSG'
cmux-tui-rust-check.sh runs cargo and runs only as a fleet step:
  cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --key KEY --os linux --arg all
  (--os macos for a test that runs only on macOS)
MSG
  exit 2
fi
mode="${1:-}"
filter="${2:-}"
case "$mode" in fmt|clippy|test|all|terminal|panic|rd-host|rd-bench|rb-testhost|vm-cli|optchat-chief|screen|api-compat|api-compat-write) ;; *) echo "usage: cmux-tui-rust-check.sh fmt|clippy|test|all|terminal|panic|rd-host|rd-bench|rb-testhost|vm-cli|optchat-chief|screen|api-compat|api-compat-write [TEST_FILTER]" >&2; exit 2 ;; esac
if [[ ( "$mode" == api-compat* || "$mode" == panic ) && -n "$filter" ]]; then
  echo "error: $mode takes no TEST_FILTER" >&2
  exit 2
fi
if [[ "$mode" == panic && "$(uname -s)" != Linux ]]; then
  echo "error: the panic mode runs only on Linux (rust-panic-baseline.json holds Linux counts; macOS compiles other cfg code): no verdict here. Run it on a Linux fleet step, an rbx lane or a Testbox." >&2
  exit 2
fi
# The crates the terminal mode tests; every other mode's tests take the whole workspace.
terminal_crates=(ghostty-vt ghostty-vt-sys cmux-pty cmux-terminal-sizing cmux-terminal-client cmux-encode)
test_scope=(--workspace)
if [[ "$mode" == terminal ]]; then
  test_scope=()
  for crate in "${terminal_crates[@]}"; do test_scope+=(-p "$crate"); done
fi
if [[ -n "$filter" && ! "$filter" =~ ^[A-Za-z0-9_:.-]{1,200}$ ]]; then
  echo "error: TEST_FILTER must be one Rust test-name substring (letters, digits, _ : . -)" >&2
  exit 2
fi
# CMUX_RUST_TEST_SHARD=i/n (cmux-ci run --shards N) runs the i-th of n nextest
# partitions (--partition count:i/n) of the workspace tests; fmt, clippy and the
# doc tests run only in shard 1, so the n steps together run each check once.
shard="${CMUX_RUST_TEST_SHARD:-}"
shard_i=1
if [[ -n "$shard" ]]; then
  if [[ ! "$shard" =~ ^([1-9][0-9]?)/([1-9][0-9]?)$ ]] || (( BASH_REMATCH[1] > BASH_REMATCH[2] )); then
    echo "error: CMUX_RUST_TEST_SHARD must be i/n with 1 <= i <= n <= 99" >&2
    exit 2
  fi
  shard_i="${BASH_REMATCH[1]}"
  case "$mode" in test|all|terminal) ;; *) echo "error: CMUX_RUST_TEST_SHARD applies only to the test, all and terminal modes" >&2; exit 2 ;; esac
  # A partition of a filtered run can hold no test, which --no-tests=fail makes red.
  [[ -z "$filter" ]] || { echo "error: CMUX_RUST_TEST_SHARD does not take a TEST_FILTER" >&2; exit 2; }
  echo "gate-notice: shard $shard (nextest --partition count:$shard)"
fi
umask 022
root="$(pwd -P)"
# Public CI keeps the step-private target directory. HQ marks managed workers
# with CMUX_FLEET_WORKER_TRUSTED and supplies this reviewed resolver so the
# pinned cmux-tui toolchain can reuse a stable target directory.
fleet_target_helper=""
if [[ "${CMUX_FLEET_WORKER_TRUSTED:-0}" == 1 ]]; then
  fleet_target_helper="$root/scripts/ci/fleet-rust-cache.sh"
  [[ -r "$fleet_target_helper" ]] || { echo "error: managed worker is missing the reviewed Rust target resolver" >&2; exit 78; }
  # shellcheck disable=SC1090
  source "$fleet_target_helper"
fi
# CMUX_RUST_CHECK_KEEP_TARGET_DIR=1 keeps the caller's CARGO_TARGET_DIR (an rbx
# lane's warm /w/target); a fleet step never sets it.
if [[ "${CMUX_RUST_CHECK_KEEP_TARGET_DIR:-0}" == 1 && -n "${CARGO_TARGET_DIR:-}" ]]; then
  echo "CARGO_TARGET_DIR kept: $CARGO_TARGET_DIR"
else
  export CARGO_TARGET_DIR="$root/.build/cmux-tui-rust-target"
fi
# The step's checkout has empty submodules; ghostty-vt-sys builds
# libghostty-vt from ghostty-next (2026-10-05, step ee99e05f: "missing
# build.zig"). Initialize the pinned commits shallowly before any cargo.
# The classic `ghostty` submodule is not needed (cmux-tui embeds ghostty-next's
# shell integration since 0c9d74bc3ea).
# A synced copy without the gitlink (rbx lanes have their own snapshot repository)
# already holds ghostty-next's files: use them.
ghostty_next_status=""
[[ "$mode" == api-compat* ]] || ghostty_next_status="$(git -C "$root" submodule status ghostty-next 2>/dev/null || true)"
if [[ "$mode" == api-compat* ]]; then
  echo "ghostty-next: not needed by $mode (cmux-api-compat builds only serde)"
elif [[ -z "$ghostty_next_status" && -f "$root/ghostty-next/build.zig" ]]; then
  echo "ghostty-next: no gitlink in this tree (a synced copy); using the files present"
elif ! git -C "$root" submodule update --init --depth 1 ghostty-next; then
  echo "error: git submodule update --init ghostty-next failed; no cargo command ran" >&2
  exit 3
fi
cd "$root/cmux-tui"
if [[ -n "$fleet_target_helper" ]]; then
  CARGO_TARGET_DIR="$(fleet_rust_target_dir cmux-tui "" "$PWD")"
  mkdir -p "$CARGO_TARGET_DIR"
  export CARGO_TARGET_DIR
fi
# The step's own RUSTUP_HOME auto-installed the pinned toolchain WITHOUT the
# components rust-toolchain.toml lists (rustup 1.29.1, 2026-10-05: `cargo fmt`
# failed with "no such command"). Install them explicitly; from this directory
# the toolchain file selects the toolchain.
if ! rustup component add clippy rustfmt; then
  echo "error: rustup component add clippy rustfmt failed; no cargo command ran" >&2
  exit 3
fi
active_toolchain="$(rustup show active-toolchain)" || { echo "error: rustup show active-toolchain failed; no cargo command ran" >&2; exit 3; }
echo "rust toolchain: $active_toolchain"
rustup component list --installed
# The toolchain cmux-tui/rust-toolchain.toml pins, the one the component add
# above covers. A mode whose workspace has no toolchain file of its own
# (optchat-chief, screen) runs under it through RUSTUP_TOOLCHAIN
# (use_pinned_toolchain). Without it the cargo-clippy and cargo-fmt proxies there
# fell back to the step RUSTUP_HOME's default, which differs by host
# (2026-10-29, step 7a7dfb66 on aws-m4pro-3: a minimal `stable` with no
# clippy or rustfmt; clippy and fmt failed in 0 s).
pinned_toolchain="${active_toolchain%% *}"
use_pinned_toolchain() { export RUSTUP_TOOLCHAIN="$pinned_toolchain"; }
# Run the pinned toolchain's own cargo, whose bin dir also holds cargo-fmt and
# cargo-clippy. The cargo on the step's PATH is not always the rustup proxy;
# then `cargo fmt` looks for cargo-fmt on PATH only (2026-10-05: step fafed265
# on cmux7 had rustfmt installed and still failed with "no such command").
toolchain_cargo="$(rustup which cargo)" || { echo "error: rustup which cargo failed" >&2; exit 3; }
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "cargo: $toolchain_cargo"
# The step's own target dir (in its checkout) may be warm: the worker's warm
# slot keeps the checkout's .build between steps. Cargo keeps another rustc's
# artifacts beside the old ones, so a new toolchain (`rustc -vV`, from the
# directory whose rust-toolchain.toml applies), a new zig (ghostty-vt-sys
# reruns its zig build only when $ZIG changes, not when the zig on PATH does)
# or a new stamp version wipes the target first. Raise warm_target_version to
# make every warm slot build cold once. A kept target
# (CMUX_RUST_CHECK_KEEP_TARGET_DIR, rbx) or a target dir outside the checkout
# (the managed fleet resolver, shared) is never wiped.
warm_target_version=1
warm_target_guard() {
  local dir="$CARGO_TARGET_DIR" stamp want have zig_version
  if [[ "${CMUX_RUST_CHECK_KEEP_TARGET_DIR:-0}" == 1 || "$dir" != "$root/.build/"* ]]; then
    echo "cargo target: $dir (kept or not this checkout's; not checked)"
    return 0
  fi
  stamp="$dir/.cmux-rust-check-stamp"
  zig_version="$("${ZIG:-zig}" version 2>/dev/null || echo none)"
  want="cmux-tui-rust-check target v$warm_target_version"$'\n'"zig $zig_version"$'\n'"$(rustc -vV)" || { echo "error: rustc -vV failed; no cargo command ran" >&2; exit 3; }
  if [[ -d "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
    have="$(cat "$stamp" 2>/dev/null || true)"
    if [[ "$have" == "$want" ]]; then
      echo "cargo target: warm ($dir, same toolchain and stamp v$warm_target_version)"
    else
      echo "cargo target: wiped ($dir: the toolchain or the stamp changed, or no stamp)"
      rm -rf "$dir"
    fi
  else
    echo "cargo target: cold ($dir is empty)"
  fi
  mkdir -p "$dir" && printf '%s\n' "$want" >"$stamp"
}
warm_target_guard
# Go's caches for cmux-tailnet's build script (crates/cmux-tailnet/build.rs runs
# `go build` for libtailscale), in this checkout's .build, which a warm slot keeps,
# so the Go toolchain libtailscale's go.mod selects and its modules are fetched
# once per slot, not into each step's own HOME. Go writes its module cache
# read-only; -modcacherw keeps it removable: before it, a step's cleanup failed
# on it ("step workspace cleanup failed: unlinkat .../home/go/pkg/mod/...:
# permission denied", 14 of 95 macOS steps on 2026-10-28) and that error
# replaced the step's own verdict.
go_caches() {
  export GOFLAGS=-modcacherw
  export GOPATH="$root/.build/go-path" GOMODCACHE="$root/.build/go-path/pkg/mod" GOCACHE="$root/.build/go-cache"
}
go_caches
# Every mode runs all of its steps, even after a red one (no fail-fast), and
# prints a summary table at the end; the step exits with the first red step's
# exit code. CMUX_RUST_CHECK_FAIL_FAST=1 restores stop-at-first-red (and cargo
# test without --no-fail-fast). Why (2026-10-15): one base-red test made the
# workspace `cargo test` stop at its crate and hid every later crate for
# every lane.
fail_fast="${CMUX_RUST_CHECK_FAIL_FAST:-0}"
first_rc=0
step_rows=()
no_fail_fast=(--no-fail-fast)
[[ "$fail_fast" != 1 ]] || no_fail_fast=()
# The same for the workspace clippy: --keep-going lints every crate after a red
# one, so one run lists every error (2026-10-29: four fleet rounds each showed
# only the next crate's errors).
keep_going=(--keep-going)
[[ "$fail_fast" != 1 ]] || keep_going=()
step() { # NAME CMD...: runs CMD, records pass/fail/skipped and seconds
  local name="$1" t0 rc=0
  shift
  if [[ "$first_rc" -ne 0 && "$fail_fast" == 1 ]]; then
    step_rows+=("$name"$'\t'"skipped (fail-fast)"$'\t'"-")
    return 0
  fi
  echo "=== step $name: $*"
  t0=$SECONDS
  "$@" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    step_rows+=("$name"$'\t'"pass"$'\t'"$((SECONDS - t0))")
  else
    step_rows+=("$name"$'\t'"FAIL (exit $rc)"$'\t'"$((SECONDS - t0))")
    [[ "$first_rc" -ne 0 ]] || first_rc=$rc
  fi
  return 0
}
# Base-red skip list (scripts/ci/cmux-tui-base-red.tsv): tests that are red on
# the base for a known reason, skipped in the cmux-tui workspace tests (`test`
# and `all`) with libtest `--skip` (a test-name substring; use the full path).
# Columns, tab-separated: FILTER BEAD EXPIRES(YYYY-MM-DD, UTC, the review date:
# after it each run warns) OS(any|macos|linux) REASON. An entry without a bead, or with a
# bad filter, date or OS, fails the step. An entry past its expiry only warns
# (a gate-notice line naming its bead) and is still applied: a calendar date
# must not turn every PR red (2026-10-20: cx-2ueez and cx-gz5dx expired and
# failed the base-red step on every PR, as a lapsed feature flag reviewBy did
# before #21967). Remove the entry in the push that fixes its test.
base_red_file="$root/scripts/ci/cmux-tui-base-red.tsv"
skip_args=()
skip_notes=()
load_base_red() {
  local today os line filter bead expires entry_os reason bad=0
  if [[ ! -f "$base_red_file" ]]; then
    echo "base-red: no scripts/ci/cmux-tui-base-red.tsv; nothing is skipped"
    return 0
  fi
  today="$(date -u +%F)"
  [[ "$today" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "gate-notice: base-red ERROR: no UTC date"; return 1; }
  case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) os=other ;; esac
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    filter="" bead="" expires="" entry_os="" reason=""
    IFS=$'\t' read -r filter bead expires entry_os reason <<<"$line"
    # --skip matches a substring in every test binary: a short filter hides too much.
    if [[ ! "$filter" =~ ^[A-Za-z0-9_:.-]{20,200}$ ]]; then
      echo "gate-notice: base-red ERROR: bad filter (20-200 of letters, digits, _ : . -; use the full test path): $line"; bad=1; continue
    fi
    if [[ ! "$bead" =~ ^[a-z][a-z0-9]*-[a-z0-9]+$ ]]; then
      echo "gate-notice: base-red ERROR: $filter has no bead id: $line"; bad=1; continue
    fi
    if [[ ! "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "gate-notice: base-red ERROR: $filter (bead $bead) has no expiry YYYY-MM-DD: $line"; bad=1; continue
    fi
    case "$entry_os" in any|macos|linux) ;; *)
      echo "gate-notice: base-red ERROR: $filter (bead $bead) OS must be any, macos or linux: $line"; bad=1; continue ;;
    esac
    if [[ "$today" > "$expires" ]]; then
      echo "gate-notice: base-red WARNING: $filter (bead $bead) expired $expires UTC and is still skipped; fix it and remove the entry"
    fi
    if [[ "$entry_os" != any && "$entry_os" != "$os" ]]; then
      echo "gate-notice: base-red not applied on $os: $filter (bead $bead, $entry_os only)"
      continue
    fi
    skip_args+=(--skip "$filter")
    skip_notes+=("gate-notice: base-red skip: $filter (bead $bead, expires $expires UTC, $entry_os): $reason")
    echo "${skip_notes[${#skip_notes[@]}-1]}"
  done <"$base_red_file"
  return "$bad"
}
# Workspace tests run under cargo-nextest: one process per test and every test
# binary at once. cargo test ran the 361 test binaries one after another
# (cmux9, 7e32a23c: 998 s of test time, 473 s of it in one binary). A test that
# fails in the full run runs once more, alone (one test at a time, after the
# full run), because the full run's reds were load reds: a different set every
# run, each green alone (beads cx-mqvyw, cx-t9m9q). A test that also fails
# alone stays red. One that passes alone is FLAKY: the step passes, and its
# name is printed as a gate-notice line (gate-run receipts keep them) and in
# the summary, so its owner sees it. The rerun is skipped (the step stays red)
# when more than CMUX_RUST_CHECK_RERUN_MAX (default 12) tests failed, when
# nextest failed for another reason than a red test (build, list), and with
# CMUX_RUST_CHECK_FAIL_FAST=1. CMUX_RUST_CHECK_RERUN_MAX=0 turns the rerun off.
# Doc tests (nextest does not run them) are their own step, only without a filter.
# A filter that matches no test is red (--no-tests=fail; cargo test was green).
nextest_version=0.9.148
ensure_nextest() {
  local have dir asset sha archive sum
  have="$(cargo nextest --version 2>/dev/null | head -n 1 || true)"
  if [[ "$have" != "cargo-nextest $nextest_version "* ]]; then
    case "$(uname -s)-$(uname -m)" in
      Darwin-*) asset=universal-apple-darwin sha=6c23b7fb4ca82c571fc8dfedbab45bfa773d45918f933170c85d21cd7f4b852b ;;
      Linux-x86_64) asset=x86_64-unknown-linux-gnu sha=223ba936714cc861a9cdedad5a8eb664dfdd69d6fbdf6cea6aa8184f523290dc ;;
      *) echo "error: no pinned cargo-nextest for $(uname -sm)" >&2; return 3 ;;
    esac
    dir="$root/.build/tools/cargo-nextest-$nextest_version"
    if [[ ! -x "$dir/cargo-nextest" ]]; then
      mkdir -p "$dir"
      archive="$dir/cargo-nextest.tar.gz"
      curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 120 --output "$archive" \
        "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$nextest_version/cargo-nextest-$nextest_version-$asset.tar.gz" \
        || { echo "error: cargo-nextest $nextest_version download failed" >&2; return 3; }
      if command -v sha256sum >/dev/null; then sum="$(sha256sum "$archive")"; else sum="$(shasum -a 256 "$archive")"; fi
      if [[ "${sum%% *}" != "$sha" ]]; then
        rm -f "$archive"
        echo "error: cargo-nextest archive sha256 ${sum%% *} is not the pinned $sha" >&2
        return 3
      fi
      # extract beside it and rename, so a broken extract never looks installed
      rm -rf "$dir/x" && mkdir -p "$dir/x" && tar -xzf "$archive" -C "$dir/x" cargo-nextest && mv "$dir/x/cargo-nextest" "$dir/cargo-nextest" \
        || { rm -rf "$dir/x" "$archive"; echo "error: cargo-nextest archive did not extract" >&2; return 3; }
      rm -rf "$dir/x" "$archive"
    fi
    export PATH="$dir:$PATH"
    have="$(cargo nextest --version 2>/dev/null | head -n 1 || true)"
  fi
  [[ "$have" == "cargo-nextest $nextest_version "* ]] || { echo "error: cargo nextest is '$have', not $nextest_version" >&2; return 3; }
  echo "cargo-nextest: $have"
}
test_log="$root/.build/cmux-tui-rust-check-test.log"
junit_full="$root/.build/cmux-tui-rust-check-junit.xml"
junit_rerun="$root/.build/cmux-tui-rust-check-rerun-junit.xml"
rerun_max="${CMUX_RUST_CHECK_RERUN_MAX:-12}"
[[ "$rerun_max" =~ ^[0-9]{1,3}$ ]] || { echo "error: CMUX_RUST_CHECK_RERUN_MAX must be a number" >&2; exit 2; }
rerun_notes=()
# a reused checkout never shows an older run's table
rm -f "$test_log" "$junit_full" "$junit_rerun"
junit_tool() { # failed FULL | expr FULL | verdict FULL RERUN | table FULL RERUN
  python3 -I - "$@" <<'PY'
import os, re, sys
import xml.etree.ElementTree as ET
op, full = sys.argv[1], sys.argv[2]
rerun = sys.argv[3] if len(sys.argv) > 3 else ""
def cases(path):
    out = []
    for tc in ET.parse(path).getroot().iter("testcase"):
        bad = any(c.tag in ("failure", "error") for c in tc)
        out.append((tc.get("classname", ""), tc.get("name", ""), bad, float(tc.get("time") or 0)))
    return out
def alone():
    # (binary, test) -> True when it failed alone, False when it passed alone
    if not rerun or not os.path.exists(rerun):
        return {}
    return {(b, n): bad for b, n, bad, _ in cases(rerun)}
failed = [(b, n) for b, n, bad, _ in cases(full) if bad]
if op == "failed":
    for b, n in failed:
        print(f"{b} {n}")
elif op == "expr":
    parts = []
    for b, n in failed:
        if not re.fullmatch(r"[A-Za-z0-9_.:/-]+", b) or not re.fullmatch(r"[A-Za-z0-9_:]+", n):
            print(f"cannot name {b} {n} in a filterset", file=sys.stderr)
            sys.exit(1)
        parts.append(f"(binary_id(={b}) & test(={n}))")
    print(" | ".join(parts))
elif op == "verdict":
    res, red = alone(), 0
    for b, n in failed:
        r = res.get((b, n))
        if r is False:
            print(f"gate-notice: FLAKY: {b} {n}: failed in the full run, passed alone; the step passes, the test's owner must fix it")
        else:
            red += 1
            print(f"gate-notice: RED: {b} {n}: failed in the full run and {'failed alone' if r else 'did not run alone'}")
    sys.exit(1 if red else 0)
elif op == "table":
    res, rows = alone(), {}
    for b, n, bad, t in cases(full):
        r = rows.setdefault(b.split("::", 1)[0], [0, 0, 0, 0.0])
        r[0 if not bad else 2 if res.get((b, n)) is False else 1] += 1
        r[3] += t
    if not rows:
        print("(no tests ran)")
        sys.exit(0)
    print(f"{'crate':<36} {'result':<6} {'passed':>7} {'failed':>7} {'flaky':>6} {'test s':>8}")
    for name in sorted(rows):
        p, f, fl, s = rows[name]
        print(f"{name:<36} {'FAIL' if f else 'FLAKY' if fl else 'pass':<6} {p:>7} {f:>7} {fl:>6} {s:>8.1f}")
    print(f"{len(rows)} crates, {sum(1 for r in rows.values() if r[1])} red, "
          f"{sum(r[2] for r in rows.values())} flaky tests (test s: sum of the full run's test times)")
PY
}
# macOS only: sample the number of allocated PTYs (/dev/ttysNNN) every 2 s
# during the full run and report the peak against kern.tty.ptmx_max (511 by
# default): a fleet Mac ran out of PTYs in one full run (cx-leo45). A sampler,
# not a synchronization: the run never waits on it. macOS removes a ttys node
# when its PTY is freed (xnu ptmx_free), so the count is PTYs in use.
pty_note=""
pty_watch_pid=""
pty_peak_file="$root/.build/cmux-tui-rust-check-pty-peak"
pty_count() { local n=0 f; for f in /dev/ttys[0-9]*; do [[ -e "$f" ]] && n=$((n + 1)); done; echo "$n"; }
pty_watch_start() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  pty_count >"$pty_peak_file"
  # its sleep ends with it: a left sleep would read as a leaked process
  ( peak="$(cat "$pty_peak_file")" s=""
    trap '[[ -z "$s" ]] || kill "$s" 2>/dev/null; exit 0' TERM
    while :; do
      n="$(pty_count)"
      if [[ "$n" -gt "$peak" ]]; then peak="$n"; echo "$peak" >"$pty_peak_file"; fi
      sleep 2 & s=$!
      wait "$s" || true
      s=""
    done ) >/dev/null 2>&1 </dev/null &
  pty_watch_pid=$!
  # a killed step must not leave the sampler running
  trap '[[ -z "$pty_watch_pid" ]] || kill "$pty_watch_pid" 2>/dev/null || true' EXIT
}
pty_watch_stop() { # START
  [[ -n "$pty_watch_pid" ]] || return 0
  kill "$pty_watch_pid" 2>/dev/null || true
  wait "$pty_watch_pid" 2>/dev/null || true
  pty_watch_pid=""
  pty_note="pty: peak $(cat "$pty_peak_file" 2>/dev/null || echo '?') allocated during the full run (at start $1; kern.tty.ptmx_max $(sysctl -n kern.tty.ptmx_max 2>/dev/null || echo '?'))"
  echo "$pty_note"
}
# Leaked processes (cx-leo45). Fixtures leave daemons that call setsid, so they
# leave every process group; on aws-m4pro-7 (job abdb2569, 2026-10-15) about
# 238 PTYs were still held by daemons of earlier tests when the run reached
# open_file_limit, which then failed alone at terminal 273 ("PTY capacity
# exhausted"). The fixtures must end their own daemons; until they do, the step
# stops what its own test run left behind before the reruns, before the doc
# tests and at the end, and prints `gate-notice: LEAKED: N processes, M PTYs
# reclaimed ...` and the leaked command lines, so the leak stays visible.
# A process is this run's when it is of this user and its environment holds
# this run's marker (CMUX_RUST_CHECK_RUN, set only on the cargo commands below),
# or its working directory or executable is inside this step's checkout or (on a
# fleet step) the step's own TMPDIR, or its parent is such a process. The roots
# follow the fleet worker's step reaper (build-fleet/cmd/worker/step_reap.go),
# which runs only after the step; children are added here. The script and its
# ancestors are never stopped; no name is matched. Hermetic acpmux tests clear
# the environment and work in the target dir, so their leaks are found only by
# the roots (a fleet target dir outside the checkout is shared, so it is not a
# root; neither is rbx's TMPDIR /t, which all lanes share). In a worker's warm
# slot the target stays inside the checkout, which this step holds alone, so
# the checkout root still covers every test binary. The PTY count is the
# host's: a concurrent job on the host changes it.
run_marker="CMUX_RUST_CHECK_RUN=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')-$$"
leak_notes=()
reap_leaked() { # WHEN: stops the leftovers of this run's tests and reports them
  local out line
  command -v python3 >/dev/null || { echo "leaked: not checked $1 (no python3)"; return 0; }
  out="$(python3 -I - "$run_marker" "$root" "$1" <<'PY'
import hashlib, os, re, signal, subprocess, sys, time
marker, root, when = sys.argv[1], sys.argv[2], sys.argv[3]
uid = os.geteuid()
darwin = sys.platform == "darwin"
def ptys():
    d = "/dev" if darwin else "/dev/pts"
    try:
        return sum(1 for n in os.listdir(d) if ((n.startswith("ttys") and n[4:].isdigit()) if darwin else n.isdigit()))
    except OSError:
        return -1
def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
roots = [root]
# A fleet step's TMPDIR is its own when the worker made it for this step:
# inside CI_JOB_DIR, or the worker's short path /tmp/cbw-<sha256(CI_JOB_DIR)[:12]>.
job, tmp = os.environ.get("CI_JOB_DIR", ""), os.environ.get("TMPDIR", "").rstrip("/")
if job.startswith("/") and tmp.startswith("/"):
    short = "/tmp/cbw-" + hashlib.sha256(job.encode()).hexdigest()[:12]
    if tmp == short or tmp.startswith(short + "/") or tmp.startswith(job.rstrip("/") + "/"):
        roots.append(tmp)
prefixes = set()
for r in roots:
    for p in (r, os.path.realpath(r)):
        p = os.path.normpath(p)
        if p not in ("/", "."):
            prefixes.add(p)
def inside(path):
    return any(path == p or path.startswith(p + "/") for p in prefixes)
procs = {}  # pid -> [ppid, command, state, seed]
if darwin:
    for line in run(["/bin/ps", "-axww", "-o", "pid=,ppid=,uid=,state=,command="]).splitlines():
        f = line.split(None, 4)
        if len(f) == 5 and f[0].isdigit() and f[2].lstrip("-").isdigit() and int(f[2]) % 2**32 == uid:
            procs[int(f[0])] = [int(f[1]), f[4], f[3], ""]
    for line in run(["/bin/ps", "-axww", "-E", "-o", "pid=,command="]).splitlines():
        f = line.split(None, 1)
        if len(f) == 2 and f[0].isdigit() and int(f[0]) in procs and re.search(r"(^| )" + re.escape(marker) + r"( |$)", f[1]):
            procs[int(f[0])][3] = "env"
    pid = 0
    for line in run(["/usr/sbin/lsof", "-nP", "-w", "-a", "-u", str(uid), "-d", "cwd,txt", "-F", "pn"]).splitlines():
        if line[:1] == "p":
            pid = int(line[1:]) if line[1:].isdigit() else 0
        elif line[:1] == "n" and pid in procs and not procs[pid][3] and inside(line[1:]):
            procs[pid][3] = line[1:]
else:
    for n in os.listdir("/proc"):
        if not n.isdigit():
            continue
        pid = int(n)
        try:
            if os.stat(f"/proc/{n}").st_uid != uid:
                continue
            stat = open(f"/proc/{n}/stat").read()
            rest = stat[stat.rindex(")") + 2:].split()
            cmd = open(f"/proc/{n}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
        except (OSError, ValueError):
            continue
        procs[pid] = [int(rest[1]), cmd or stat[stat.index("(") + 1:stat.rindex(")")], rest[0], ""]
        try:
            if marker.encode() in open(f"/proc/{n}/environ", "rb").read().split(b"\0"):
                procs[pid][3] = "env"
        except OSError:
            pass
        for link in ("cwd", "exe"):
            if procs[pid][3]:
                break
            try:
                target = os.readlink(f"/proc/{n}/{link}")
            except OSError:
                continue
            if inside(target.removesuffix(" (deleted)")):
                procs[pid][3] = target
# never this script, its ancestors (the step runner) or pid 1
keep, p = {1, os.getpid()}, os.getppid()
while p > 1 and p not in keep:
    keep.add(p)
    p = procs[p][0] if p in procs else 0
found = {pid for pid, v in procs.items() if v[3] and pid not in keep and v[2][:1] != "Z"}
grew = True
while grew:  # what a leftover started is a leftover too
    grew = False
    for pid, v in procs.items():
        if pid not in found and pid not in keep and v[0] in found and v[2][:1] != "Z":
            found.add(pid)
            grew = True
if not found:
    print(f"leaked: none {when}")
    sys.exit(0)
before = ptys()
for pid in sorted(found):
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
def living(pids):  # the pids that still run (not gone, not zombies)
    out = set()
    if darwin:
        if pids:
            for line in run(["/bin/ps", "-o", "pid=,state=", "-p", ",".join(map(str, sorted(pids)))]).splitlines():
                f = line.split()
                if len(f) == 2 and f[0].isdigit() and f[1][:1] != "Z":
                    out.add(int(f[0]))
        return out & pids
    for pid in pids:
        try:
            st = open(f"/proc/{pid}/stat").read()
            if st[st.rindex(")") + 2] != "Z":
                out.add(pid)
        except (OSError, ValueError):
            pass
    return out
deadline = time.monotonic() + 15  # a bounded wait for the kills to finish
left = living(found)
while left and time.monotonic() < deadline:
    time.sleep(0.2)
    left = living(left)
after = ptys()
freed = before - after if before >= 0 and after >= 0 else "?"
print(f"gate-notice: LEAKED: {len(found)} processes, {freed} PTYs reclaimed {when} (fixtures must end their own daemons: cx-leo45)")
if left:
    print(f"leaked: {len(left)} still running after SIGKILL: {' '.join(map(str, sorted(left)))}")
groups = {}
for pid in found:
    key = re.sub(r"\d+", "N", procs[pid][1])[:200]
    groups[key] = groups.get(key, 0) + 1
print(f"leaked {when}, by command (digits as N):")
for key, n in sorted(groups.items(), key=lambda kv: -kv[1])[:40]:
    print(f"  {n:5d}  {key}")
print(f"leaked {when}, each process (pid ppid matched-by command):")
for pid in sorted(found)[:600]:
    v = procs[pid]
    print(f"  {pid} {v[0]} {'env' if v[3] == 'env' else 'child' if not v[3] else 'path'} {v[1][:300]}")
PY
)" || { [[ -z "$out" ]] || echo "$out"; echo "leaked: check failed $1"; return 0; }
  while IFS= read -r line; do
    echo "$line"
    [[ "$line" != "gate-notice: "* ]] || leak_notes+=("$line")
  done <<<"$out"
  return 0
}
workspace_tests() {
  # nextest's store is target/nextest under the workspace, not under CARGO_TARGET_DIR.
  local junit="$root/cmux-tui/target/nextest/ci/junit.xml" rc rrc vrc n expr verdict line
  local args=(nextest run "${test_scope[@]}" --locked --profile ci --no-tests=fail)
  [[ "$fail_fast" != 1 ]] || args+=(--fail-fast)
  [[ -z "$shard" ]] || args+=(--partition "count:$shard")
  [[ -z "$filter" ]] || args+=("$filter")
  [[ "${#skip_args[@]}" -eq 0 ]] || args+=(-- "${skip_args[@]}")
  mkdir -p "$(dirname "$test_log")"
  rm -f "$junit"
  local pty_start=""
  [[ "$(uname -s)" != Darwin ]] || pty_start="$(pty_count)"
  pty_watch_start
  env "$run_marker" cargo "${args[@]}" 2>&1 | tee "$test_log"
  rc="${PIPESTATUS[0]}"
  pty_watch_stop "$pty_start"
  # The custom test groups (nextest.toml [test-groups]) and their tests, so a
  # step shows which tests ran alone. The run above built every binary.
  echo "=== nextest test groups (profile ci)"
  cargo nextest show-config test-groups "${test_scope[@]}" --locked --profile ci 2>&1 || echo "test groups: show-config failed"
  reap_leaked "after the full run, before reruns"
  [[ ! -f "$junit" ]] || cp "$junit" "$junit_full"
  [[ "$rc" -ne 0 ]] || return 0
  # nextest exits 100 when a test failed; any other code (build, list) stays red.
  if [[ "$rc" -ne 100 || "$fail_fast" == 1 || "$rerun_max" -eq 0 || ! -f "$junit_full" ]]; then
    echo "rerun: none (nextest exit $rc)"
    return "$rc"
  fi
  n="$(junit_tool failed "$junit_full" | wc -l | tr -d ' ')" || n=0
  if [[ "$n" -eq 0 ]]; then
    echo "rerun: none (exit $rc and no failed test in the JUnit file)"
    return "$rc"
  fi
  if [[ "$n" -gt "$rerun_max" ]]; then
    echo "gate-notice: rerun skipped: $n tests failed (more than CMUX_RUST_CHECK_RERUN_MAX=$rerun_max); every one is red"
    return "$rc"
  fi
  expr="$(junit_tool expr "$junit_full")" || { echo "rerun: none (a failed test name does not fit a filterset)"; return "$rc"; }
  echo "=== rerun: the $n failed tests, each alone (--test-threads 1)"
  rm -f "$junit"
  env "$run_marker" cargo nextest run "${test_scope[@]}" --locked --profile ci --no-tests=fail --test-threads 1 -E "$expr" 2>&1 | tee -a "$test_log"
  rrc="${PIPESTATUS[0]}"
  [[ ! -f "$junit" ]] || cp "$junit" "$junit_rerun"
  vrc=0
  verdict="$(junit_tool verdict "$junit_full" "$junit_rerun")" || vrc=$?
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "$line"
    rerun_notes+=("$line")
  done <<<"$verdict"
  [[ "$vrc" -eq 0 && "$rrc" -eq 0 ]] && return 0
  return "$rc"
}
doc_tests() {
  local args=(test --workspace --locked --doc ${no_fail_fast[@]+"${no_fail_fast[@]}"})
  [[ "${#skip_args[@]}" -eq 0 ]] || args+=(-- "${skip_args[@]}")
  reap_leaked "before doc tests"
  env "$run_marker" cargo "${args[@]}"
}
# A warm target (a fleet warm slot, an rbx lane's /w/target) keeps every
# artifact of every commit it built: cargo never deletes one. On aws-m4pro-9
# (2026-10-17) debug/deps held 491,261 files (a fresh build: about 26,800), and
# every test process spent about 14 s in SecCodeCopySelf (cmux_link's
# own-code check), which scans the executable's folder: tests of 0.2 s took
# 14-55 s and a shard ran 3569 s with 44 time-outs. prune_target keeps in
# deps/ only the units this commit's build uses (cargo reports every artifact,
# fresh or rebuilt, with --message-format=json) and deletes the rest. Build
# again with the same flags, so cargo only reports: no unit is rebuilt.
prune_target() {
  local deps="$CARGO_TARGET_DIR/debug/deps" list
  [[ -d "$deps" ]] || return 0
  list="$(mktemp "${TMPDIR:-/tmp}/rust-check-artifacts.XXXXXX")"
  if ! cargo test --workspace --locked --no-run --message-format=json >"$list" 2>/dev/null \
    || { [[ "$mode" == all ]] && ! cargo clippy --workspace --exclude cmux-holder-v3 --all-targets --locked --message-format=json >>"$list" 2>/dev/null; }; then
    rm -f "$list"
    echo "prune: skipped (cargo did not list the build's artifacts)"
    return 0
  fi
  python3 - "$deps" "$list" <<'PY' || echo "prune: failed (the target is kept)"
import json, os, shutil, sys
deps, listing = sys.argv[1], sys.argv[2]
def stem(name):
    # libfoo-0123abcd.rlib, foo-0123abcd.d, foo-0123abcd (a test binary), foo-0123abcd.dSYM
    name = name.split(".", 1)[0]
    return name[3:] if name.startswith("lib") else name
keep = set()
for line in open(listing, encoding="utf-8", errors="replace"):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") != "compiler-artifact":
        continue
    for f in (m.get("filenames") or []) + ([m["executable"]] if m.get("executable") else []):
        if os.path.dirname(f) == deps:
            keep.add(stem(os.path.basename(f)))
names = os.listdir(deps)
if len(keep) < 100:
    print(f"prune: skipped ({len(keep)} units listed, {len(names)} files in deps)")
    sys.exit(0)
gone = 0
for n in names:
    if stem(n) in keep:
        continue
    p = os.path.join(deps, n)
    if os.path.isdir(p) and not os.path.islink(p):
        shutil.rmtree(p, ignore_errors=True)
    else:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    gone += 1
print(f"prune: debug/deps kept {len(names) - gone} files of {len(keep)} units, deleted {gone} stale files")
PY
  rm -f "$list"
}
crate_table() {
  [[ -f "$junit_full" ]] || { echo "(no JUnit file: per-crate table unavailable)"; return 0; }
  command -v python3 >/dev/null || { echo "(no python3: per-crate table unavailable)"; return 0; }
  junit_tool table "$junit_full" "$junit_rerun" || echo "(per-crate table failed)"
}
finish() {
  echo
  echo "=== cmux-tui-rust-check summary (mode $mode${filter:+, filter $filter}${shard:+, shard $shard}, $( [[ "$fail_fast" == 1 ]] && echo fail-fast || echo no-fail-fast ))"
  printf '%-28s %-22s %s\n' step result seconds
  local row
  for row in "${step_rows[@]}"; do
    IFS=$'\t' read -r a b c <<<"$row"
    printf '%-28s %-22s %s\n' "$a" "$b" "$c"
  done
  if [[ "$mode" == test || "$mode" == all || "$mode" == terminal ]] && [[ -f "$test_log" ]]; then
    echo
    crate_table
  fi
  [[ "${#skip_notes[@]}" -eq 0 ]] || printf '%s\n' "${skip_notes[@]}"
  [[ "${#rerun_notes[@]}" -eq 0 ]] || printf '%s\n' "${rerun_notes[@]}"
  [[ "${#leak_notes[@]}" -eq 0 ]] || printf '%s\n' "${leak_notes[@]}"
  [[ -z "$pty_note" ]] || echo "$pty_note"
  if [[ "$first_rc" -ne 0 ]]; then
    echo "cmux-tui-rust-check: RED (first red step exit $first_rc)"
  else
    echo "cmux-tui-rust-check: green"
  fi
  exit "$first_rc"
}
if [[ "$mode" == optchat-chief ]]; then
  # Its own workspace and lockfile, so its own target dir.
  export CARGO_TARGET_DIR="$root/.build/optchat-chief-target"
  cd "$root/Native/OptChat/optchat-chief"
  use_pinned_toolchain
  warm_target_guard
  # Its tests bind Unix sockets under the temp dir; the step's own TMPDIR is
  # longer than SUN_LEN (step b1563a89: "path must be shorter than SUN_LEN").
  short_tmp="$(mktemp -d /tmp/occ.XXXXXX)"
  trap 'rm -rf "$short_tmp"' EXIT
  export TMPDIR="$short_tmp"
  step "optchat-chief test" cargo test ${no_fail_fast[@]+"${no_fail_fast[@]}"} ${filter:+"$filter"}
  step "optchat-chief clippy" cargo clippy --all-targets -- -D warnings
  step "optchat-chief fmt" cargo fmt --check
  finish
fi
if [[ "$mode" == rd-host ]]; then
  # Its own workspace and lockfile, so its own target dir.
  export CARGO_TARGET_DIR="$root/.build/cmux-rd-host-target"
  cd "$root/cmux-tui/crates/cmux-rd-host"
  warm_target_guard
  step "rd-host fmt" cargo fmt --check
  step "rd-host clippy" cargo clippy --locked --all-targets --no-default-features --features bench -- -D warnings
  step "rd-host test" cargo test --locked ${no_fail_fast[@]+"${no_fail_fast[@]}"} --no-default-features --features bench ${filter:+"$filter"}
  finish
fi
copy_rd_bench() {
  mkdir -p "$root/.build/artifacts"
  cp "$CARGO_TARGET_DIR/release/cmux-rd" "$root/.build/artifacts/cmux-rd" || return 1
  ls -l "$root/.build/artifacts/cmux-rd"
}
if [[ "$mode" == rd-bench ]]; then
  export CARGO_TARGET_DIR="$root/.build/cmux-rd-host-target"
  cd "$root/cmux-tui/crates/cmux-rd-host"
  warm_target_guard
  step "rd-bench release build" cargo build --locked --release --no-default-features --features bench
  step "rd-bench artifact" copy_rd_bench
  finish
fi
# Go for libtailscale (cmux-screen/crates/cmux-tailnet/build.rs): the host's go
# with GOTOOLCHAIN=auto (Go 1.21 or later) when it has one, else the pinned
# release (cmux-tui/crates/cmux-tailnet/go-version, which cmux-tui.yml's macOS
# job installs too), checksummed, in the step's own .build. Go's caches stay in
# .build (go_caches), and toolchain downloads go only through the default
# proxy with the checksum database on: nothing is installed on the host.
ensure_screen_go() {
  export GOTOOLCHAIN=auto GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org
  go_caches
  local version arch sum dir tmp
  version="$(tr -d '[:space:]' <"$root/cmux-tui/crates/cmux-tailnet/go-version")" || return 3
  dir="$root/.build/go-$version"
  if ! command -v go >/dev/null 2>&1; then
    case "$version-$(uname -m)" in
      1.27.1-arm64) arch=arm64; sum=ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12 ;;
      1.27.1-x86_64) arch=amd64; sum=8f8f52c6649542cf027bbc9b9c68d1ec042f9f34808a40413f0b8b3f66f3caa4 ;;
      *) echo "error: no pinned sha256 for Go $version on $(uname -m); add it here" >&2; return 3 ;;
    esac
    if [[ ! -x "$dir/go/bin/go" ]]; then
      # Extract beside the target and rename, so a cut-off extract never looks complete.
      tmp="$dir.partial"
      rm -rf "$dir" "$tmp" && mkdir -p "$tmp" || return 3
      curl -fsSL -o "$tmp/go.tgz" "https://go.dev/dl/go$version.darwin-$arch.tar.gz" || return 3
      echo "$sum  $tmp/go.tgz" | shasum -a 256 -c - || return 3
      tar -xzf "$tmp/go.tgz" -C "$tmp" && rm -f "$tmp/go.tgz" && mv "$tmp" "$dir" || return 3
    fi
    export PATH="$dir/go/bin:$PATH"
  fi
  # libtailscale's go.mod selects the Go of go-version; GOTOOLCHAIN=auto switches to it inside that folder.
  go version || return 3
}
if [[ "$mode" == screen ]]; then
  if [[ ! -f "$root/cmux-screen/Cargo.toml" ]]; then
    echo "error: screen mode: no cmux-screen workspace at this commit" >&2
    exit 2
  fi
  export CARGO_TARGET_DIR="$root/.build/cmux-screen-target"
  cd "$root/cmux-screen"
  use_pinned_toolchain
  warm_target_guard
  step "screen go" ensure_screen_go
  step "screen clippy" cargo clippy --locked --workspace --all-targets -- -D warnings
  step "screen test" cargo test --locked --workspace ${no_fail_fast[@]+"${no_fail_fast[@]}"} ${filter:+"$filter"}
  step "screen release build" cargo build --locked --release -p cmux-screen-host
  step "tailnet release build" cargo build --locked --release --manifest-path "$root/cmux-tui/Cargo.toml" -p cmux-tailnet
  finish
fi
copy_testhost() {
  mkdir -p "$root/.build/artifacts"
  cp "$CARGO_TARGET_DIR/release/cmux-remote-browser-testhost" "$root/.build/artifacts/cmux-remote-browser-testhost" || return 1
  ls -l "$root/.build/artifacts/cmux-remote-browser-testhost"
}
if [[ "$mode" == rb-testhost ]]; then
  export CARGO_TARGET_DIR="$root/.build/cmux-rb-testhost-target"
  cd "$root/cmux-tui/crates/cmux-remote-browser-testhost"
  warm_target_guard
  step "rb-testhost fmt" cargo fmt --check
  step "rb-testhost clippy" cargo clippy --locked --all-targets -- -D warnings
  step "rb-testhost test" cargo test --locked ${no_fail_fast[@]+"${no_fail_fast[@]}"} ${filter:+"$filter"}
  step "rb-testhost release build" cargo build --locked --release
  step "rb-testhost artifact" copy_testhost
  finish
fi
copy_vm_cli() {
  mkdir -p "$root/.build/artifacts"
  cp "$CARGO_TARGET_DIR/release/cmux-vm" "$root/.build/artifacts/cmux-vm" || return 1
  ls -l "$root/.build/artifacts/cmux-vm"
}
if [[ "$mode" == vm-cli ]]; then
  export CARGO_TARGET_DIR="$root/.build/cmux-vm-cli-target"
  cd "$root/workers/cmux-vm/cli"
  warm_target_guard
  step "vm-cli clippy" cargo clippy --locked --workspace --all-targets -- -D warnings
  step "vm-cli test" cargo test --locked --workspace ${no_fail_fast[@]+"${no_fail_fast[@]}"} ${filter:+"$filter"}
  step "vm-cli release build" cargo build --locked --release -p cmux-vm
  step "vm-cli artifact" copy_vm_cli
  finish
fi
# The files --write may write: the shape snapshot, and the wire ledger where the crate has one.
api_compat_files=(cmux-tui/spec/api-compat.surface.json cmux-tui/spec/api-compat.wire.json)
# Packs those files (the ones present) into the step's artifact and says what --write changed.
api_compat_pack() {
  local files=() f stat
  for f in "${api_compat_files[@]}"; do [[ ! -f "$root/$f" ]] || files+=("$f"); done
  [[ "${#files[@]}" -gt 0 ]] || { echo "error: no api-compat spec file to return" >&2; return 1; }
  mkdir -p "$root/.build/artifacts"
  # No AppleDouble ._* entries from a macOS worker (bsdtar); GNU tar ignores the variable.
  COPYFILE_DISABLE=1 tar -C "$root" -cf "$root/.build/artifacts/api-compat-spec.tar" "${files[@]}" || return 1
  stat="$(git -C "$root" --no-pager diff --no-color --no-ext-diff --stat -- "${files[@]}")" || return 1
  if [[ -n "$stat" ]]; then
    echo "api-compat-write: changed: $stat"
  else
    echo "api-compat-write: ${files[*]} unchanged (already current)"
  fi
  echo "api-compat-write: .build/artifacts/api-compat-spec.tar holds ${files[*]}; run tar -xf on it at your checkout root"
}
if [[ "$mode" == api-compat ]]; then
  step "api-compat check" cargo run --locked -p cmux-api-compat --bin api-compat-check
  finish
fi
if [[ "$mode" == api-compat-write ]]; then
  # A warm slot keeps .build: never hand back an older step's files.
  rm -f "$root/.build/artifacts/api-compat-spec.tar"
  step "api-compat write" cargo run --locked -p cmux-api-compat --bin api-compat-check -- --write
  [[ "$first_rc" -ne 0 ]] || step "api-compat pack" api_compat_pack
  finish
fi
# panic: cmux-tui.yml's "Rust panic ratchet" step (Linux lint job), the same commands from the same
# directory (cmux-tui): production targets only, every workspace crate against its baseline.
panic_ratchet() {
  local flags rc=0 json="$root/.build/artifacts/panic-clippy.jsonl"
  read -r -a flags <<<"$(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags)"
  ((${#flags[@]})) || { echo "error: rust_panic_ratchet.py --flags printed no flags" >&2; return 3; }
  mkdir -p "$root/.build/artifacts"
  cargo clippy --workspace --lib --bins --locked --message-format=json -- "${flags[@]}" >"$json" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # --message-format=json sends the compiler's errors to the file only: print them, so the log says why.
    echo "panic ratchet: cargo clippy failed (exit $rc) before the ratchet could count; its errors:" >&2
    python3 -c 'import json, sys
for line in open(sys.argv[1], errors="replace"):
    try: m = json.loads(line)
    except ValueError: continue
    msg = m.get("message") or {}
    if m.get("reason") == "compiler-message" and msg.get("level") in ("error", "error: internal compiler error"):
        sys.stderr.write(msg.get("rendered") or msg.get("message") or "")' "$json" || true
    return "$rc"
  fi
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json "$json"
}
if [[ "$mode" == panic ]]; then
  step "panic ratchet" panic_ratchet
  finish
fi
if [[ "$mode" == fmt || "$mode" == all ]] && [[ "$shard_i" == 1 ]]; then
  step fmt cargo fmt --all --check
fi
if [[ "$mode" == clippy || "$mode" == all ]] && [[ "$shard_i" == 1 ]]; then
  # The frozen holder fixture (cmux-holder-v3) is an old shipped holder, never edited: no new
  # lint may fail it (its own [lints] allow everything; `-D warnings` here would override them).
  step clippy cargo clippy --workspace --exclude cmux-holder-v3 --all-targets --locked ${keep_going[@]+"${keep_going[@]}"} -- -D warnings
fi
if [[ "$mode" == test || "$mode" == all ]]; then
  step "base-red list" load_base_red
  step "cargo-nextest" ensure_nextest
  step "workspace tests" workspace_tests
  if [[ -z "$filter" && "$shard_i" == 1 ]]; then
    step "doc tests" doc_tests
  fi
  # A Testbox or another host without a step reaper keeps what the run left.
  reap_leaked "at the end of the step"
  # Only after a build that cargo finished: a failed build lists no artifacts.
  step "prune target" prune_target
fi
if [[ "$mode" == terminal ]]; then
  step "base-red list" load_base_red
  step "cargo-nextest" ensure_nextest
  step "terminal tests" workspace_tests
  reap_leaked "at the end of the step"
fi
finish
