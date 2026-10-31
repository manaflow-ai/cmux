#!/usr/bin/env bash
# Runs the cmux-tui/fuzz work on a Linux fleet machine (the build pool, label
# cmux-next-linux), never on a developer Mac or an agent VM. One mode a run:
#
#   run-fleet.sh fuzz TARGET SECONDS [SANITIZER]   cargo-fuzz (libFuzzer) with ASan
#                                                  (default) or "none"; UBSan-class
#                                                  checks come from Rust's debug
#                                                  assertions (overflow, bounds), on
#                                                  in cargo-fuzz builds
#   run-fleet.sh live [ROUNDS]                     the live concurrent-client test
#   run-fleet.sh live-tsan [ROUNDS]                the same under ThreadSanitizer
#   run-fleet.sh tsan [FILTER]                     cmux-tui-core's daemon tests
#                                                  (server, diagnostics, journal
#                                                  ingress) under ThreadSanitizer
#   run-fleet.sh loom                              the loom models (cargo test --cfg loom)
#   run-fleet.sh check                             compile every target, test and model
#
# Each run ends with one line `FUZZ-VERDICT <mode> PASS|FAIL <reason>|NOVERDICT
# <reason>` (fuzz/verdict.py reads it). Crash inputs are printed base64 between
# `FUZZ-ARTIFACT-BEGIN <name>` and `FUZZ-ARTIFACT-END` lines so the log alone
# carries the repro. The nightly toolchain, rust-src and cargo-fuzz are
# installed into the job's cache when the image lacks them (it does: STATUS
# 2026-10-31 06:30Z).
set -uo pipefail
umask 022

mode="${1:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tui="$(cd "$here/.." && pwd)"
root="$(cd "$tui/.." && pwd)"
nightly="${CMUX_FUZZ_NIGHTLY:-nightly-2026-10-20}"
cache="${CMUX_FUZZ_CACHE:-$HOME/.cache/cmux-tui-fuzz}"
target_triple="x86_64-unknown-linux-gnu"

verdict() { echo "FUZZ-VERDICT $mode $*"; }
die_noverdict() { verdict "NOVERDICT $*"; exit 3; }

[[ "$(uname -s)" == Linux ]] || die_noverdict "Linux only (the sanitizers and libFuzzer runs are Linux fleet work)"
[[ -n "${CMUX_FUZZ_FLEET:-}${CMUX_CI_STEP_KEY:-}" ]] || die_noverdict "runs only as a fleet job (set CMUX_FUZZ_FLEET=1 there)"

mkdir -p "$cache"
# Its own CARGO_HOME and RUSTUP_HOME: the nightly goes into the job's cache,
# never into the image's toolchains (the pool's build keys read those). The
# rustup proxies come from the image (/home/cmux/.cargo/bin on a pool VM).
export CARGO_HOME="$cache/cargo"
export RUSTUP_HOME="$cache/rustup"
export PATH="$CARGO_HOME/bin:/home/cmux/.cargo/bin:$HOME/.cargo/bin:/opt/zig-0.16.0:$PATH"
export CMUX_GHOSTTY_VT_ZIG_CPU="${CMUX_GHOSTTY_VT_ZIG_CPU:-baseline}"
mkdir -p "$CARGO_HOME/bin"

need_nightly() {
  if ! rustup run "$nightly" rustc --version >/dev/null 2>&1; then
    echo "installing $nightly (the pool image has stable only)"
    rustup toolchain install "$nightly" --profile minimal --component rust-src >/dev/null || die_noverdict "rustup could not install $nightly"
  fi
  rustup component add --toolchain "$nightly" rust-src >/dev/null 2>&1 || die_noverdict "rustup could not add rust-src to $nightly"
  echo "toolchain: $(rustup run "$nightly" rustc --version)"
}

need_cargo_fuzz() {
  if ! command -v cargo-fuzz >/dev/null 2>&1; then
    echo "installing cargo-fuzz into $CARGO_HOME"
    cargo +"$nightly" install --locked cargo-fuzz --version 0.13.1 >/dev/null 2>&1 \
      || cargo +"$nightly" install --locked cargo-fuzz >/dev/null 2>&1 || die_noverdict "cargo install cargo-fuzz failed"
  fi
}

need_ghostty() {
  if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
    git -C "$root" submodule update --init --depth 1 ghostty-next >/dev/null 2>&1 || die_noverdict "ghostty-next submodule"
  fi
}

# The fuzz workspace has its own lockfile, seeded from cmux-tui's so every
# shared dependency stays at the version the daemon ships with.
need_lock() {
  if [[ ! -f "$here/Cargo.lock" ]]; then
    cp "$tui/Cargo.lock" "$here/Cargo.lock"
    (cd "$here" && cargo +"$nightly" metadata --format-version 1 >/dev/null) || die_noverdict "resolve the fuzz workspace"
    echo "FUZZ-ARTIFACT-BEGIN Cargo.lock"
    gzip -9c "$here/Cargo.lock" | base64 -w0
    echo
    echo "FUZZ-ARTIFACT-END"
  fi
}

# TSan reports tokio's IO driver races that go through epoll (rust-san-4 in
# handoff/concurrency-find-rust-san.md: reproduced with tokio alone).
write_tsan_suppressions() {
  local file="$cache/tsan.supp"
  printf '%s\n' 'race:tokio::runtime::io::scheduled_io' 'race:tokio::runtime::io::registration_set' > "$file"
  echo "$file"
}

print_artifacts() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/crash-* "$dir"/leak-* "$dir"/timeout-* "$dir"/oom-*; do
    [[ -f "$f" ]] || continue
    echo "FUZZ-ARTIFACT-BEGIN $(basename "$f")"
    base64 -w0 "$f"
    echo
    echo "FUZZ-ARTIFACT-END"
  done
}

case "$mode" in
  fuzz)
    target="${2:-}"
    seconds="${3:-600}"
    sanitizer="${4:-address}"
    [[ "$target" =~ ^[a-z_]+$ && -f "$here/fuzz_targets/$target.rs" ]] || die_noverdict "unknown target '$target'"
    [[ "$seconds" =~ ^[0-9]+$ ]] || die_noverdict "SECONDS must be a number"
    need_nightly; need_cargo_fuzz; need_ghostty; need_lock
    corpus="$cache/corpus/$target"
    mkdir -p "$corpus"
    [[ -d "$here/corpus/$target" ]] && cp -n "$here/corpus/$target"/* "$corpus"/ 2>/dev/null
    artifacts="$here/artifacts/$target"
    mkdir -p "$artifacts"
    # cargo-fuzz looks for ./fuzz under the cwd unless told; name the
    # directory. Workers write fuzz-N.log into the cwd.
    cd "$tui"
    rm -f "$tui"/fuzz-*.log
    jobs="${CMUX_FUZZ_JOBS:-$(( $(nproc) / 2 ))}"
    echo "fuzz $target for ${seconds}s, sanitizer $sanitizer, $jobs workers, corpus $(ls "$corpus" | wc -l) inputs"
    export ASAN_OPTIONS="detect_leaks=1:allocator_may_return_null=0:abort_on_error=1:symbolize=1"
    set +e
    cargo +"$nightly" fuzz run --fuzz-dir "$here" --sanitizer "$sanitizer" --debug-assertions "$target" "$corpus" -- \
      -max_total_time="$seconds" -rss_limit_mb=4096 -max_len=1048576 -timeout=20 \
      -jobs="$jobs" -workers="$jobs" -print_final_stats=1 2>&1 | tee "$cache/fuzz-$target.log" | \
      grep -E "^#[0-9]+.*(INITED|DONE|pulse)|stat::|==[0-9]+==|ERROR|panicked|SUMMARY|Test unit written|thread '" | tail -200
    rc=${PIPESTATUS[0]}
    set -e
    # libFuzzer workers log to fuzz-N.log in the cwd.
    for log in "$tui"/fuzz-*.log; do
      [[ -f "$log" ]] || continue
      grep -h -E "stat::number_of_executed_units|stat::peak_rss_mb|ERROR|panicked at|SUMMARY" "$log" | head -40
    done
    execs=$(cat "$tui"/fuzz-*.log "$cache/fuzz-$target.log" 2>/dev/null | grep -h "stat::number_of_executed_units" | awk '{s+=$2} END {print s+0}')
    print_artifacts "$artifacts"
    echo "corpus after: $(ls "$corpus" | wc -l) inputs; executions: $execs"
    if ls "$artifacts"/crash-* "$artifacts"/leak-* "$artifacts"/oom-* "$artifacts"/timeout-* >/dev/null 2>&1; then
      verdict "FAIL $target: $(ls "$artifacts" | head -3 | tr '\n' ' ')execs=$execs"
      exit 1
    fi
    if [[ $rc -ne 0 ]]; then
      verdict "NOVERDICT $target: cargo fuzz exited $rc with no crash artifact (build or setup failure) execs=$execs"
      exit 3
    fi
    verdict "PASS $target execs=$execs seconds=$seconds sanitizer=$sanitizer"
    ;;
  live|live-tsan)
    rounds="${2:-3}"
    [[ "$rounds" =~ ^[0-9]+$ ]] || die_noverdict "ROUNDS must be a number"
    need_ghostty
    export CMUX_WIRE_FUZZ_ROUNDS="$rounds"
    cd "$here"
    set +e
    if [[ "$mode" == live ]]; then
      need_nightly; need_lock
      cargo +"$nightly" test --release -p cmux-tui-fuzz-live -- --nocapture 2>&1 | tail -150
      rc=${PIPESTATUS[0]}
    else
      need_nightly; need_lock
      supp="$(write_tsan_suppressions)"
      export CMUX_WIRE_FUZZ_WITNESS_MS="${CMUX_WIRE_FUZZ_WITNESS_MS:-10000}"
      export TSAN_OPTIONS="suppressions=$supp:halt_on_error=0:second_deadlock_stack=1:report_signal_unsafe=0"
      RUSTFLAGS="-Zsanitizer=thread -Cforce-frame-pointers=yes" RUSTDOCFLAGS="-Zsanitizer=thread" \
        cargo +"$nightly" test -Zbuild-std --target "$target_triple" -p cmux-tui-fuzz-live -- --nocapture 2>&1 | \
        tee "$cache/live-tsan.log" | grep -E "WIRE-FUZZ-RESULT|WARNING: ThreadSanitizer|SUMMARY: ThreadSanitizer|test result|panicked|error(\[|:)" | tail -150
      rc=${PIPESTATUS[0]}
      grep -A30 "WARNING: ThreadSanitizer" "$cache/live-tsan.log" | head -400
    fi
    set -e
    if [[ "$mode" == live-tsan ]] && grep -q "WARNING: ThreadSanitizer" "$cache/live-tsan.log"; then
      verdict "FAIL tsan reports: $(grep -c 'WARNING: ThreadSanitizer' "$cache/live-tsan.log")"
      exit 1
    fi
    case $rc in
      0) verdict "PASS rounds=$rounds" ;;
      101) verdict "FAIL the live test failed (see WIRE-FUZZ-RESULT)"; exit 1 ;;
      *) verdict "NOVERDICT cargo exited $rc (build failure)"; exit 3 ;;
    esac
    ;;
  tsan)
    filter="${2:-}"
    [[ -z "$filter" || "$filter" =~ ^[A-Za-z0-9_:]+$ ]] || die_noverdict "bad FILTER"
    need_nightly; need_ghostty
    supp="$(write_tsan_suppressions)"
    export TSAN_OPTIONS="suppressions=$supp:halt_on_error=0:second_deadlock_stack=1:report_signal_unsafe=0"
    cd "$tui"
    filters=(server:: diagnostics journal_ingress mux::)
    [[ -n "$filter" ]] && filters=("$filter")
    set +e
    # The workspace lockfile, read only (--locked): the TSan build changes no
    # dependency. Its own target dir so the stable build cache stays untouched.
    for f in "${filters[@]}"; do
      echo "=== tsan cmux-tui-core $f"
      CARGO_TARGET_DIR="$cache/tsan-target" RUSTFLAGS="-Zsanitizer=thread -Cforce-frame-pointers=yes" \
        cargo +"$nightly" test --locked -Zbuild-std --target "$target_triple" -p cmux-tui-core --lib -- "$f" --test-threads 8 2>&1 | \
        tee -a "$cache/tsan.log" | grep -E "WARNING: ThreadSanitizer|SUMMARY: ThreadSanitizer|test result|panicked|^error" | tail -60
    done
    set -e
    grep -A30 "WARNING: ThreadSanitizer" "$cache/tsan.log" | head -600
    warnings=$(grep -c "WARNING: ThreadSanitizer" "$cache/tsan.log")
    results=$(grep -c "^test result" "$cache/tsan.log")
    failed=$(grep -E "^test result: FAILED" -c "$cache/tsan.log")
    if [[ "$results" -eq 0 ]]; then verdict "NOVERDICT no test ran (build failure)"; exit 3; fi
    if [[ "$warnings" -gt 0 || "$failed" -gt 0 ]]; then verdict "FAIL tsan_reports=$warnings failed_runs=$failed"; exit 1; fi
    verdict "PASS filters=${filters[*]}"
    ;;
  loom)
    need_nightly; need_lock
    cd "$here"
    set +e
    RUSTFLAGS="--cfg loom" cargo +"$nightly" test --release -p cmux-tui-loom -- --nocapture --test-threads 4 2>&1 | tail -120
    rc=${PIPESTATUS[0]}
    set -e
    case $rc in
      0) verdict "PASS" ;;
      101) verdict "FAIL a loom model failed"; exit 1 ;;
      *) verdict "NOVERDICT cargo exited $rc (build failure)"; exit 3 ;;
    esac
    ;;
  check)
    need_nightly; need_ghostty; need_lock
    cd "$here"
    rc=0
    # NAME TARGET_DIR RUSTFLAGS CARGO_ARGS...: one cargo check, its errors printed.
    check_one() {
      local name="$1" dir="$2" flags="$3"
      shift 3
      echo "=== check $name"
      if ! CARGO_TARGET_DIR="$dir" RUSTFLAGS="$flags" cargo +"$nightly" check "$@" > "$cache/check-$name.log" 2>&1; then
        rc=1
      fi
      grep -E -A12 "^(warning|error)" "$cache/check-$name.log" | head -300
    }
    check_one fuzzing "$cache/check-fuzzing" "--cfg fuzzing" -p cmux-tui-fuzz --bins
    check_one live "$cache/check-live" "" -p cmux-tui-fuzz-live --tests
    check_one loom "$cache/check-loom" "--cfg loom" -p cmux-tui-loom --tests
    if [[ $rc -eq 0 ]]; then verdict "PASS"; else verdict "FAIL a target does not compile"; exit 1; fi
    ;;
  *)
    echo "usage: run-fleet.sh fuzz TARGET SECONDS [address|none] | live [ROUNDS] | live-tsan [ROUNDS] | tsan [FILTER] | loom | check" >&2
    exit 2
    ;;
esac
