#!/usr/bin/env bash
# CMUX-570 (bundle size), cut 3 of cmuxterm-hq docs/perf/bundle-size.md: what panic=abort
# saves on the shipped Rust helpers. One source tree, one toolchain, one machine: each
# binary is built twice with its shipping settings, once with panic=unwind (what the
# base ships) and once with panic=abort, then stripped the same way and compared.
# Fleet only:
#   cmux-ci run --class exclusive --os macos --script scripts/measure/panic-abort-size.sh --ref SHA
# Optional arguments name extra binaries to measure without shipping them:
#   cmux     bin/cmux (cmux-tui = acpmux = cmux, the multicall binary)
#   chief    optchat-chief
# Writes report.tsv and the binaries' sizes to $FAST_CHECKS_OUT (or artifacts/panic-abort-size).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/cmux-next/lib/fleet-only.sh
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet panic-abort-size.sh 'cargo build' 'CMUX-570 panic=abort size comparison'
[[ "$(uname -s)" == Darwin ]] || { echo "panic-abort-size.sh measures the macOS app's binaries; run it on a macOS worker" >&2; exit 2; }
out="${FAST_CHECKS_OUT:-$root/artifacts/panic-abort-size}"
work="${PANIC_ABORT_SIZE_WORK:-$root/target/panic-abort-size}"
mkdir -p "$out" "$work"
target=aarch64-apple-darwin
# shellcheck source=scripts/lib/rust-targets.sh
source "$root/scripts/lib/rust-targets.sh"

extra=" $* "
report="$out/report.tsv"
printf 'binary\tpanic\tbytes_stripped\tunwind_section_bytes\tsha256\n' > "$report"

unwind_bytes() {
  size -m -l "$1" | awk '/Section (__eh_frame|__gcc_except_tab|__unwind_info):/ { gsub(":", "", $3); s += $3 } END { print s + 0 }'
}

# record NAME PANIC BUILT_BINARY: strip a copy as the app bundle does (local symbols out)
# and append its bytes, unwind section bytes and digest.
record() {
  local name=$1 panic=$2 built=$3 copy="$out/$1-$2"
  [[ -x "$built" ]] || { echo "error: $built was not built" >&2; exit 1; }
  cp -f "$built" "$copy"
  strip -x "$copy"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$panic" "$(stat -f %z "$copy")" "$(unwind_bytes "$copy")" \
    "$(shasum -a 256 "$copy" | awk '{print $1}')" >> "$report"
}

# smoke NAME PANIC ARGS...: the abort build must run its help or version path like the unwind one.
smoke() {
  local name=$1 panic=$2
  shift 2
  "$out/$name-$panic" "$@" > "$out/$name-$panic.smoke" 2>&1 || { echo "error: $name ($panic) $* failed" >&2; cat "$out/$name-$panic.smoke" >&2; exit 1; }
}

for panic in unwind abort; do
  # cmux-mobile-host: scripts/cmux-next/build-mobile-host.sh's size profile.
  (cd "$root/cmux-next-ios/rust" && ensure_rust_targets "$target" &&
    CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 CARGO_PROFILE_RELEASE_PANIC=$panic \
    CARGO_TARGET_DIR="$work/mobile-host-$panic" \
    cargo build --locked --release --package cmux-mobile-host --bin cmux-mobile-host --target "$target")
  record cmux-mobile-host "$panic" "$work/mobile-host-$panic/$target/release/cmux-mobile-host"
  smoke cmux-mobile-host "$panic" --help

  # cmux-agent-screen-detection: its own workspace's release profile, panic overridden per arm.
  (cd "$root/cmux-tui" && CARGO_PROFILE_RELEASE_PANIC=$panic CARGO_TARGET_DIR="$work/screen-detection-$panic" \
    cargo build --manifest-path bindings/examples/rust-agent-screen-detection/Cargo.toml \
      --release --locked --target "$target")
  record cmux-agent-screen-detection "$panic" "$work/screen-detection-$panic/$target/release/cmux-agent-screen-detection"
  smoke cmux-agent-screen-detection "$panic" --help

  if [[ "$extra" == *" chief "* ]]; then
    (cd "$root/Native/OptChat" && CARGO_PROFILE_RELEASE_PANIC=$panic CARGO_TARGET_DIR="$work/chief-$panic" \
      cargo build --locked --release -p optchat-chief --bin optchat-chief --target "$target")
    record optchat-chief "$panic" "$work/chief-$panic/$target/release/optchat-chief"
  fi

  if [[ "$extra" == *" cmux "* ]]; then
    (cd "$root/cmux-tui" && CARGO_PROFILE_RELEASE_PANIC=$panic CARGO_TARGET_DIR="$work/cmux-$panic" \
      cargo build --locked --release -p cmux-tui --bin cmux-tui --target "$target")
    record cmux "$panic" "$work/cmux-$panic/$target/release/cmux-tui"
    smoke cmux "$panic" --version
  fi
done

# The two arms differ only in the panic strategy, so every binary must differ in bytes.
awk -F'\t' 'NR > 1 { key = $1; if ($2 == "unwind") u[key] = $3; else a[key] = $3 }
  END {
    total = 0
    for (k in u) {
      if (!(k in a)) { print "error: no abort arm for " k > "/dev/stderr"; exit 1 }
      d = u[k] - a[k]; total += d
      printf "%-30s unwind %11d  abort %11d  saved %10d B (%.2f MB, %.1f%%)\n", k, u[k], a[k], d, d / 1e6, 100 * d / u[k]
    }
    printf "%-30s saved %10d B (%.2f MB)\n", "all measured", total, total / 1e6
  }' "$report" | tee "$out/summary.txt"
echo "source: $(git -C "$root" rev-parse HEAD) rustc: $(cd "$root/cmux-tui" && rustc --version)" | tee -a "$out/summary.txt"
