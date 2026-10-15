#!/usr/bin/env bash
# cmux-tui's Rust checks on a macOS fleet host, as a cmux-ci step:
#   cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA --key KEY \
#     --arg MODE [--arg TEST_FILTER]
# MODE: fmt (cargo fmt --check), clippy (-D warnings), test [FILTER], or all [FILTER];
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
test_log="$root/.build/cmux-tui-rust-check-test.log"
rm -f "$test_log" "$test_log.meta"   # a reused checkout never shows an older run's table
workspace_tests() {
  local args=(test --workspace --locked ${no_fail_fast[@]+"${no_fail_fast[@]}"})
  [[ -z "$filter" ]] || args+=("$filter")
  [[ "${#skip_args[@]}" -eq 0 ]] || args+=(-- "${skip_args[@]}")
  mkdir -p "$(dirname "$test_log")"
  cargo "${args[@]}" 2>&1 | tee "$test_log"
  return "${PIPESTATUS[0]}"
}
# Per-crate table of a workspace test run: each test binary's result line,
# mapped to its package through `cargo metadata` (cargo prints only the
# package-relative source path and the binary name).
crate_table() {
  [[ -f "$test_log" ]] || return 0
  command -v python3 >/dev/null || { echo "(no python3: per-crate table unavailable)"; return 0; }
  cargo metadata --no-deps --format-version 1 --locked 2>/dev/null >"$test_log.meta" && [[ -s "$test_log.meta" ]] || { echo "(cargo metadata failed: per-crate table unavailable)"; return 0; }
  python3 -I - "$test_log" "$test_log.meta" <<'PY' || echo "(per-crate table failed)"
import json, re, sys
log, meta = sys.argv[1:]
by_bin, by_lib = {}, {}
for pkg in json.load(open(meta))["packages"]:
    for t in pkg["targets"]:
        name = t["name"].replace("-", "_")
        by_bin.setdefault(name, []).append((t["src_path"], pkg["name"]))
        if "lib" in t["kind"] or "proc-macro" in t["kind"] or "rlib" in t["kind"]:
            by_lib[name] = pkg["name"]
# A binary's own result is the LAST "test result" line before the next binary:
# tests that run the test binary again as a child print nested result lines.
# cargo's "error: test failed, to rerun pass `-p PKG ...`" marks a red binary
# also when it crashed before its result line.
rows, cur, last = {}, None, None
def row(name):
    return rows.setdefault(name, [0, 0, 0.0, False])
def close():
    global cur, last
    if cur is not None:
        r = row(cur)   # no result line (a binary or doctest set with no tests): pass unless cargo says otherwise
        if last is not None:
            r[0] += last[0]; r[1] += last[1]; r[2] += last[2]; r[3] = r[3] or last[3]
    cur, last = None, None
for line in open(log, errors="replace"):
    m = re.match(r"\s+Running (\S+(?: \S+)?) \((.+)\)$", line)
    d = re.match(r"\s+Doc-tests (\S+)$", line)
    if m or d:
        close()
        if m:
            src, binary = m.group(1).replace("unittests ", ""), m.group(2)
            stem = re.sub(r"-[0-9a-f]{16}$", "", binary.rsplit("/", 1)[-1])
            cands = by_bin.get(stem, [])
            hits = [p for s, p in cands if s.endswith("/" + src)] or [p for _, p in cands]
            cur = hits[0] if hits else stem
        else:
            cur = by_lib.get(d.group(1), d.group(1))
        continue
    r = re.match(r"test result: (\w+)\. (\d+) passed; (\d+) failed;.*finished in ([\d.]+)s", line)
    if r and cur is not None:
        last = (int(r.group(2)), int(r.group(3)), float(r.group(4)), r.group(1) != "ok")
        continue
    e = re.match(r"error: test failed, to rerun pass `-p (\S+)", line)
    if e:
        if cur is not None and last is None:
            cur = e.group(1)   # the crashed binary's package, as cargo names it
        close()
        row(e.group(1))[3] = True
close()
if not rows:
    print("(no test binaries ran)"); sys.exit(0)
print(f"{'crate':<36} {'result':<6} {'passed':>7} {'failed':>7} {'test s':>8}")
for name in sorted(rows):
    p, f, s, bad = rows[name]
    print(f"{name:<36} {'FAIL' if bad else 'pass':<6} {p:>7} {f:>7} {s:>8.1f}")
print(f"{len(rows)} crates, {sum(1 for r in rows.values() if r[3])} red")
PY
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
  step "workspace tests" workspace_tests
fi
finish
