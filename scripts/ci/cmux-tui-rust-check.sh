#!/usr/bin/env bash
# cmux-tui's Rust checks on a macOS fleet host, as a cmux-ci step:
#   cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --key KEY \
#     --arg MODE [--arg TEST_FILTER]
# MODE: fmt (cargo fmt --check), clippy (-D warnings), test [FILTER] (cargo nextest, a
# failed test reruns once alone: see workspace_tests), or all [FILTER];
# optchat-chief [FILTER]: tests, clippy -D warnings and fmt --check of
# Native/OptChat/optchat-chief (its own workspace and lockfile), tests first so
# a red run still reports them; without --locked, so a new dependency resolves
# into its Cargo.lock (return it with --artifact Native/OptChat/optchat-chief/Cargo.lock);
# rd-host: clippy and tests of cmux-tui/crates/cmux-rd-host (its own workspace, so the
# modes above never build it) on macOS, including its VideoToolbox path, without x264
# (no libx264 on the fleet) and with the bench feature (OpenH264 from source).
# rb-testhost: fmt, clippy and tests of cmux-tui/crates/cmux-remote-browser-testhost
# (its own workspace), then its release binary at .build/artifacts/cmux-remote-browser-testhost
# (macOS arm64; fetch it with --artifact) for the remote tab's GUI proofs.
# optchat-chief: fmt, clippy and tests of Native/OptChat/optchat-chief (its own workspace)
# on macOS, where the Chief host runs: its macOS-only code (the acpmux socket peer check,
# cx-ggai: LOCAL_PEERPID, proc_pidpath, the Security framework) runs only here.
# The fleet may run cargo through cmux-ci (coordinator, 2026-10-04); a developer
# Mac never runs it (the laptop and the minis by hand stay off limits), so
# outside a step (CMUX_CI_STEP_KEY) it refuses. The target dir is the step's
# own (.build/cmux-tui-rust-target in its checkout), and files are created
# with umask 022.
set -euo pipefail
if [[ -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  cat >&2 <<'MSG'
cmux-tui-rust-check.sh runs cargo and runs only as a fleet step:
  cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --key KEY --arg all
MSG
  exit 2
fi
mode="${1:-}"
filter="${2:-}"
case "$mode" in fmt|clippy|test|all|rd-host|rb-testhost|optchat-chief) ;; *) echo "usage: cmux-tui-rust-check.sh fmt|clippy|test|all|rd-host|rb-testhost|optchat-chief [TEST_FILTER]" >&2; exit 2 ;; esac
if [[ -n "$filter" && ! "$filter" =~ ^[A-Za-z0-9_:.-]{1,200}$ ]]; then
  echo "error: TEST_FILTER must be one Rust test-name substring (letters, digits, _ : . -)" >&2
  exit 2
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
ghostty_next_status="$(git -C "$root" submodule status ghostty-next 2>/dev/null || true)"
if [[ -z "$ghostty_next_status" && -f "$root/ghostty-next/build.zig" ]]; then
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
echo "rust toolchain: $(rustup show active-toolchain)"
rustup component list --installed
# Run the pinned toolchain's own cargo, whose bin dir also holds cargo-fmt and
# cargo-clippy. The cargo on the step's PATH is not always the rustup proxy;
# then `cargo fmt` looks for cargo-fmt on PATH only (2026-10-05: step fafed265
# on cmux7 had rustfmt installed and still failed with "no such command").
toolchain_cargo="$(rustup which cargo)" || { echo "error: rustup which cargo failed" >&2; exit 3; }
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "cargo: $toolchain_cargo"
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
# Columns, tab-separated: FILTER BEAD EXPIRES(YYYY-MM-DD, UTC, the last day the
# skip applies) OS(any|macos|linux) REASON. An entry without a bead, with a bad
# filter, date or OS, or past its expiry fails the step; an expired entry is
# not skipped, so its test runs again.
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
      echo "gate-notice: base-red EXPIRED: $filter (bead $bead, expired $expires UTC); the test runs; fix it or remove the entry"
      bad=1; continue
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
  ( peak="$(cat "$pty_peak_file")"
    while :; do
      n="$(pty_count)"
      if [[ "$n" -gt "$peak" ]]; then peak="$n"; echo "$peak" >"$pty_peak_file"; fi
      sleep 2
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
workspace_tests() {
  # nextest's store is target/nextest under the workspace, not under CARGO_TARGET_DIR.
  local junit="$root/cmux-tui/target/nextest/ci/junit.xml" rc rrc vrc n expr verdict line
  local args=(nextest run --workspace --locked --profile ci --no-tests=fail)
  [[ "$fail_fast" != 1 ]] || args+=(--fail-fast)
  [[ -z "$filter" ]] || args+=("$filter")
  [[ "${#skip_args[@]}" -eq 0 ]] || args+=(-- "${skip_args[@]}")
  mkdir -p "$(dirname "$test_log")"
  rm -f "$junit"
  local pty_start=""
  [[ "$(uname -s)" != Darwin ]] || pty_start="$(pty_count)"
  pty_watch_start
  cargo "${args[@]}" 2>&1 | tee "$test_log"
  rc="${PIPESTATUS[0]}"
  pty_watch_stop "$pty_start"
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
  cargo nextest run --workspace --locked --profile ci --no-tests=fail --test-threads 1 -E "$expr" 2>&1 | tee -a "$test_log"
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
  cargo "${args[@]}"
}
crate_table() {
  [[ -f "$junit_full" ]] || { echo "(no JUnit file: per-crate table unavailable)"; return 0; }
  command -v python3 >/dev/null || { echo "(no python3: per-crate table unavailable)"; return 0; }
  junit_tool table "$junit_full" "$junit_rerun" || echo "(per-crate table failed)"
}
finish() {
  echo
  echo "=== cmux-tui-rust-check summary (mode $mode${filter:+, filter $filter}, $( [[ "$fail_fast" == 1 ]] && echo fail-fast || echo no-fail-fast ))"
  printf '%-28s %-22s %s\n' step result seconds
  local row
  for row in "${step_rows[@]}"; do
    IFS=$'\t' read -r a b c <<<"$row"
    printf '%-28s %-22s %s\n' "$a" "$b" "$c"
  done
  if [[ "$mode" == test || "$mode" == all ]] && [[ -f "$test_log" ]]; then
    echo
    crate_table
  fi
  [[ "${#skip_notes[@]}" -eq 0 ]] || printf '%s\n' "${skip_notes[@]}"
  [[ "${#rerun_notes[@]}" -eq 0 ]] || printf '%s\n' "${rerun_notes[@]}"
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
  step "rd-host fmt" cargo fmt --check
  step "rd-host clippy" cargo clippy --locked --all-targets --no-default-features --features bench -- -D warnings
  step "rd-host test" cargo test --locked ${no_fail_fast[@]+"${no_fail_fast[@]}"} --no-default-features --features bench ${filter:+"$filter"}
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
  step "rb-testhost fmt" cargo fmt --check
  step "rb-testhost clippy" cargo clippy --locked --all-targets -- -D warnings
  step "rb-testhost test" cargo test --locked ${no_fail_fast[@]+"${no_fail_fast[@]}"} ${filter:+"$filter"}
  step "rb-testhost release build" cargo build --locked --release
  step "rb-testhost artifact" copy_testhost
  finish
fi
if [[ "$mode" == fmt || "$mode" == all ]]; then
  step fmt cargo fmt --all --check
fi
if [[ "$mode" == clippy || "$mode" == all ]]; then
  step clippy cargo clippy --workspace --all-targets --locked -- -D warnings
fi
if [[ "$mode" == test || "$mode" == all ]]; then
  step "base-red list" load_base_red
  step "cargo-nextest" ensure_nextest
  step "workspace tests" workspace_tests
  if [[ -z "$filter" ]]; then
    step "doc tests" doc_tests
  fi
fi
finish
