#!/usr/bin/env bash
# Rust sanitizer and Miri lane for cmux-tui.
#
# Runs the tests of the listed crates under ASan, TSan or LSan (nextest with
# -Zbuild-std, so std is instrumented too) and the pure crates under Miri, with
# the nightly pinned in cmux-tui/sanitize/rust-toolchain.toml. The workspace
# toolchain and Cargo.lock are never changed (--locked, and checked after the
# run). Every sanitizer report and Miri error becomes a findings.jsonl line,
# signed by scripts/cmux-next/crash_signature.py. See cmux-tui/docs/sanitizers.md.
#
# Chromium's model: one instrumented build per sanitizer
# (build/config/sanitizers/BUILD.gn, -fno-omit-frame-pointer), runtime defaults
# from build/sanitizers/sanitizer_options.cc, and reports written per process
# through log_path. Linux ASan checks leaks in the same process, as Chromium's
# ASan bots do; the separate leak mode covers macOS, whose ASan has no leak
# checker, and plain LSan's conservative scan.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANITIZE_DIR="$TUI_DIR/sanitize"
TOOLCHAIN_FILE="$SANITIZE_DIR/rust-toolchain.toml"
NEXTEST_TOOL_CONFIG="$SANITIZE_DIR/nextest.toml"
COLLECTOR="$SANITIZE_DIR/collect_findings.py"
TEST_RUNNER="$SANITIZE_DIR/test-runner.sh"

SANITIZER_CRATES_LINUX=(cmux-tui-core acpmux cmux-holder cmux-pty ghostty-vt)
SANITIZER_CRATES_MACOS=(cmux-pty cmux-holder)
MIRI_CRATES=(cmux-pane-protocol cmux-remote-protocol cmux-rd-proto cmux-layout-reducer)
ALL_MODES=(address thread leak miri)

usage() {
  cat <<'EOF'
usage: cmux-tui/scripts/sanitize.sh [options] [-- extra nextest args]

  --sanitizer LIST   comma list of address,thread,leak,miri (default: all four)
  --crate NAME       run only this crate (repeatable; replaces the default
                     list of every selected mode)
  --out FILE         findings JSONL (default: WORK/findings.jsonl)
  --runs FILE        one line per crate run (default: WORK/runs.jsonl)
  --work-dir DIR     target dirs and logs
                     (default: $CMUX_SANITIZE_WORK_DIR or cmux-tui/target/sanitize)
  --workspace DIR    cargo workspace to test (default: cmux-tui)
  --install          install the pinned nightly and its components first
  --list             print the toolchain, modes and crates, run nothing
  --dry-run          print the commands, run nothing
  -h, --help         this text

Default crates: address, thread and leak run cmux-tui-core, acpmux,
cmux-holder, cmux-pty and ghostty-vt on Linux, and cmux-pty and cmux-holder
on macOS; miri runs cmux-pane-protocol, cmux-remote-protocol, cmux-rd-proto
and cmux-layout-reducer.

Exit status: 0 when every run passed with no finding (a Miri run whose only red
tests are operations Miri cannot run counts as passed), 1 on a finding or a
red run, 2 on a usage or setup error.
EOF
}

die() {
  echo "sanitize.sh: $*" >&2
  exit 2
}

modes_arg="address,thread,leak,miri"
crates=()
out=""
runs=""
work_dir="${CMUX_SANITIZE_WORK_DIR:-}"
workspace="$TUI_DIR"
install=0
list_only=0
dry_run=0
extra=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sanitizer) [[ $# -ge 2 ]] || die "--sanitizer needs a value"; modes_arg="$2"; shift 2 ;;
    --sanitizer=*) modes_arg="${1#*=}"; shift ;;
    --crate) [[ $# -ge 2 ]] || die "--crate needs a value"; crates+=("$2"); shift 2 ;;
    --crate=*) crates+=("${1#*=}"); shift ;;
    --out) [[ $# -ge 2 ]] || die "--out needs a value"; out="$2"; shift 2 ;;
    --out=*) out="${1#*=}"; shift ;;
    --runs) [[ $# -ge 2 ]] || die "--runs needs a value"; runs="$2"; shift 2 ;;
    --runs=*) runs="${1#*=}"; shift ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir needs a value"; work_dir="$2"; shift 2 ;;
    --work-dir=*) work_dir="${1#*=}"; shift ;;
    --workspace) [[ $# -ge 2 ]] || die "--workspace needs a value"; workspace="$2"; shift 2 ;;
    --workspace=*) workspace="${1#*=}"; shift ;;
    --install) install=1; shift ;;
    --list) list_only=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; extra=("$@"); break ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

IFS=',' read -r -a modes <<<"$modes_arg"
[[ ${#modes[@]} -gt 0 ]] || die "--sanitizer is empty"
for mode in "${modes[@]}"; do
  case " ${ALL_MODES[*]} " in
    *" $mode "*) ;;
    *) die "unknown sanitizer '$mode' (address, thread, leak, miri)" ;;
  esac
done

workspace="$(cd "$workspace" 2>/dev/null && pwd)" || die "no workspace directory"
[[ -f "$workspace/Cargo.toml" ]] || die "$workspace has no Cargo.toml"
work_dir="${work_dir:-$workspace/target/sanitize}"
mkdir -p "$work_dir"
work_dir="$(cd "$work_dir" && pwd)"

# Sanitizer options and the runner's TOML string quote paths with ' (the
# options parser splits values on spaces, commas and colons); a path holding
# one cannot be quoted there.
no_quote() {
  [[ "$2" != *"'"* ]] || die "$1 contains a ' and cannot be passed to the sanitizer runtime: $2"
}
no_quote "the work directory" "$work_dir"
no_quote "the lane directory" "$SANITIZE_DIR"
out="${out:-$work_dir/findings.jsonl}"
runs="${runs:-$work_dir/runs.jsonl}"

channel="$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$TOOLCHAIN_FILE")"
[[ -n "$channel" ]] || die "no channel in $TOOLCHAIN_FILE"

case "$(uname -s)" in
  Linux) os=linux; asan_detect_leaks=1; default_sanitizer_crates=("${SANITIZER_CRATES_LINUX[@]}") ;;
  Darwin) os=macos; asan_detect_leaks=0; default_sanitizer_crates=("${SANITIZER_CRATES_MACOS[@]}") ;;
  *) die "sanitizers run on Linux and macOS only" ;;
esac

crates_for() {
  if [[ ${#crates[@]} -gt 0 ]]; then
    printf '%s\n' "${crates[@]}"
  elif [[ "$1" == miri ]]; then
    printf '%s\n' "${MIRI_CRATES[@]}"
  else
    printf '%s\n' "${default_sanitizer_crates[@]}"
  fi
}

if [[ $install -eq 1 && $dry_run -eq 0 ]]; then
  # rustup installs the toolchain file's channel with its profile and components.
  (cd "$SANITIZE_DIR" && rustup toolchain install)
fi

if [[ $list_only -eq 1 ]]; then
  echo "toolchain $channel ($TOOLCHAIN_FILE)"
  echo "os $os"
  for mode in "${modes[@]}"; do
    echo "$mode: $(crates_for "$mode" | tr '\n' ' ')"
  done
  exit 0
fi

if [[ $dry_run -eq 1 ]]; then
  host="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
  host="${host:-HOST}"
  sysroot="SYSROOT"
  rustc_hash="HASH"
else
  rustup run "$channel" rustc -V >/dev/null 2>&1 || die "toolchain $channel is not installed; rerun with --install"
  rustup run "$channel" cargo nextest --version >/dev/null 2>&1 || die "cargo-nextest is not installed"
  host="$(rustup run "$channel" rustc -vV | sed -n 's/^host: //p')"
  rustc_hash="$(rustup run "$channel" rustc -vV | sed -n 's/^commit-hash: //p')"
  sysroot="$(rustup run "$channel" rustc --print sysroot)"
  [[ -d "$sysroot/lib/rustlib/src/rust/library" ]] || die "$channel has no rust-src; rerun with --install"
fi
commit="$(git -C "$workspace" rev-parse HEAD 2>/dev/null || echo unknown)"

# The acceptance of this lane: it never touches the workspace's lockfile or
# toolchain. --locked makes cargo refuse a lockfile change; this catches the rest.
guarded_files=(Cargo.lock rust-toolchain.toml)
guard_state() {
  git -C "$workspace" status --porcelain -- "${guarded_files[@]}" 2>/dev/null || true
  (cd "$workspace" && cksum "${guarded_files[@]}" 2>/dev/null) || true
}
guard_before="$(guard_state)"

# Symbolized frames are what crash_signature.py hashes. The runtime runs
# llvm-symbolizer (atos on macOS); without one it falls back to addr2line.
symbolizer=""
for candidate in "${LLVM_SYMBOLIZER:-}" llvm-symbolizer; do
  [[ -n "$candidate" ]] && symbolizer="$(command -v "$candidate" 2>/dev/null || true)"
  [[ -n "$symbolizer" ]] && break
done
if [[ -z "$symbolizer" ]]; then
  for candidate in /usr/lib/llvm-*/bin/llvm-symbolizer /opt/homebrew/opt/llvm/bin/llvm-symbolizer; do
    [[ -x "$candidate" ]] && symbolizer="$candidate"
  done
fi
# One frame shape for the three runtimes: `#N PC in FUNCTION FILE:LINE:COL`,
# or `(MODULE+0xOFFSET)` for a frame with no source. Inlined frames stay, one
# line each, as ClusterFuzz keeps them: crash_signature.py drops std's by their
# /rustc/ file and names an inlined user function by its own.
symbolizer_opts="symbolize=1:stack_trace_format='    #%n %p %F %L'"
if [[ -n "$symbolizer" ]]; then
  no_quote "the symbolizer path" "$symbolizer"
  symbolizer_opts+=":external_symbolizer_path='$symbolizer'"
elif [[ $os == linux ]]; then
  symbolizer_opts+=":allow_addr2line=1"
fi

run_cmd() {
  if [[ $dry_run -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

if [[ $dry_run -eq 0 ]]; then
  : >"$out"
  : >"$runs"
fi

SEP=$'\x1f'
status=0
for mode in "${modes[@]}"; do
  target_dir="$work_dir/target-$mode"
  while IFS= read -r crate; do
    [[ -n "$crate" ]] || continue
    run_dir="$work_dir/logs/$mode/$crate"
    events="$run_dir/events.jsonl"
    nextest_log="$run_dir/nextest.log"
    tests_map="$run_dir/tests.tsv"
    if [[ $dry_run -eq 0 ]]; then
      rm -rf "$run_dir"
      mkdir -p "$run_dir"
    fi
    common=(--manifest-path "$workspace/Cargo.toml" -p "$crate" --locked --no-fail-fast
      --tool-config-file "sanitize:$NEXTEST_TOOL_CONFIG"
      --message-format libtest-json-plus)
    log_opt="log_path='$run_dir/report'"
    if [[ $mode == miri ]]; then
      env_args=(CARGO_TARGET_DIR="$target_dir" NEXTEST_EXPERIMENTAL_LIBTEST_JSON=1)
      cmd=(cargo miri nextest run "${common[@]}" --profile miri)
    else
      # Remapping rust-src to /rustc/<hash> gives std's frames the files of a
      # prebuilt std, which the signature's `file:^/rustc/` rule drops.
      # The encoded form (0x1f between flags) keeps a sysroot path with spaces whole.
      rustflags="-Zsanitizer=$mode${SEP}-Cforce-frame-pointers=yes"
      rustflags+="${SEP}--remap-path-prefix=$sysroot/lib/rustlib/src/rust=/rustc/$rustc_hash"
      env_args=(CARGO_TARGET_DIR="$target_dir" NEXTEST_EXPERIMENTAL_LIBTEST_JSON=1
        CARGO_ENCODED_RUSTFLAGS="$rustflags" CMUX_SANITIZE_TESTS="$tests_map"
        # Chromium's Linux ASan runs LSan in the same process; ASan's
        # allocator makes it see leaks plain LSan's conservative scan misses.
        # macOS ASan has no leak checker; the leak config covers it there.
        ASAN_OPTIONS="$log_opt:$symbolizer_opts:detect_leaks=$asan_detect_leaks"
        LSAN_OPTIONS="$log_opt:$symbolizer_opts"
        # Every race, not the first; detached test threads are not findings.
        TSAN_OPTIONS="$log_opt:$symbolizer_opts:halt_on_error=0:report_thread_leaks=0:second_deadlock_stack=1:history_size=7")
      # The runner writes each test process's pid and test name, so report.<pid>
      # names its test.
      cmd=(cargo nextest run "${common[@]}" --profile sanitize -Zbuild-std --target "$host"
        --config "target.$host.runner=['$TEST_RUNNER']")
    fi
    echo "sanitize: $mode $crate" >&2
    exit_code=0
    if [[ $dry_run -eq 1 ]]; then
      run_cmd env "${env_args[@]}" rustup run "$channel" "${cmd[@]}" ${extra[@]+"${extra[@]}"}
      continue
    fi
    (cd "$workspace" && env "${env_args[@]}" nice -n 10 rustup run "$channel" "${cmd[@]}" ${extra[@]+"${extra[@]}"}) \
      >"$events" 2>"$nextest_log" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      tail -n 20 "$nextest_log" >&2
    fi
    python3 -I "$COLLECTOR" --tool "$mode" --crate "$crate" --os "$os" --target "$host" \
      --toolchain "$channel" --commit "$commit" --sysroot "$sysroot" --exit "$exit_code" \
      --log-dir "$run_dir" --tests "$tests_map" --events "$events" --nextest-log "$nextest_log" \
      --out "$out" --runs "$runs" || status=1
  done < <(crates_for "$mode")
done

if [[ $dry_run -eq 1 ]]; then
  exit 0
fi
if [[ "$(guard_state)" != "$guard_before" ]]; then
  echo "sanitize.sh: the run changed $workspace/Cargo.lock or rust-toolchain.toml; it must not" >&2
  status=1
fi
findings="$(wc -l <"$out" | tr -d ' ')"
echo "sanitize: $findings unique findings in $out; runs in $runs" >&2
exit "$status"
