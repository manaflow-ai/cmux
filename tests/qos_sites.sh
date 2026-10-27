#!/usr/bin/env bash
# Q12 of plans/cmux-next/chrome-parity/p01-process.md (task p01-process-139):
# every thread the terminal process model starts declares its QoS. A thread
# outside test code starts through `cmux_threads::spawn` (or another
# cmux-threads or thread_qos starter), which registers it and sets its class
# before its body runs; a raw `std::thread::Builder::new()` or
# `std::thread::spawn(` inherits its creator's class and has no registry row.
#
# Run in the agent loop (fleet or local), not in CI:
#   tests/qos_sites.sh              check this checkout
#   tests/qos_sites.sh --self-test  check the scanner on fixtures
# Exit 0: no raw site. Exit 1: each raw site is printed as path:line.
set -euo pipefail

# The Q12 scan roots, relative to the repository root. Missing roots (the VT
# pool and VT worker of tasks 120 and 124 before they land) are skipped.
Q12_ROOTS=(
  cmux-tui/crates/cmux-holder/src
  cmux-tui/crates/cmux-tui-core/src/holder_runtime
  cmux-tui/crates/cmux-tui-core/src/holder_runtime.rs
  cmux-tui/crates/cmux-tui-core/src/vt_pool
  cmux-tui/crates/cmux-tui-core/src/vt_pool.rs
  cmux-tui/crates/cmux-vt-worker/src
)

# Prints path:line for each raw thread start in non-test code of one file.
# Test code: a `*_tests.rs` file, and everything from a `#[cfg(test)]` that
# opens an inline module (`mod name {`) to the end of the file, the
# repository's layout for inline test modules. An out-of-line declaration
# (`#[cfg(test)] mod name;`) is only that line; the scan goes on after it.
raw_sites_in() {
  awk -v file="$1" '
    pending && /^[[:space:]]*(pub(\([a-z]+\))?[[:space:]]+)?mod[[:space:]]+[A-Za-z0-9_]+[[:space:]]*;/ { pending = 0; next }
    pending && /^[[:space:]]*(pub(\([a-z]+\))?[[:space:]]+)?mod[[:space:]]/ { exit }
    pending && !/^[[:space:]]*#\[/ { pending = 0 }
    /^[[:space:]]*#\[cfg\(test\)\][[:space:]]*$/ { pending = 1; next }
    /^[[:space:]]*\/\// { next }
    /thread::Builder::new\(\)|thread::spawn\(/ { print file ":" FNR }
  ' "$1"
}

# Scans the Q12 roots under $1; prints every raw site, returns 1 if any.
scan() {
  local root="$1" found=0 entry file
  for entry in "${Q12_ROOTS[@]}"; do
    [[ -e "$root/$entry" ]] || continue
    while IFS= read -r file; do
      case "$file" in
        *_tests.rs | */tests/*) continue ;;
      esac
      while IFS= read -r site; do
        echo "${site#"$root"/}: raw thread start with no declared QoS (use cmux_threads::spawn)"
        found=1
      done < <(raw_sites_in "$file")
    done < <(find "$root/$entry" -name '*.rs' -type f | sort)
  done
  return "$found"
}

self_test() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local src="$dir/cmux-tui/crates/cmux-holder/src"
  mkdir -p "$src/holder"
  cat >"$src/clean.rs" <<'RUST'
// A comment naming std::thread::spawn( is not a site.
fn start() {
    let _ = cmux_threads::spawn("ok", cmux_threads::ThreadQos::Utility, || {});
}

#[cfg(test)]
#[path = "x.rs"]
mod tests {
    fn t() {
        std::thread::spawn(|| {});
    }
}
RUST
  cat >"$src/holder/clean_tests.rs" <<'RUST'
fn t() { std::thread::spawn(|| {}); }
RUST
  if ! out="$(scan "$dir")"; then
    echo "self-test: test code was reported: $out" >&2
    return 1
  fi
  cat >"$src/holder/raw.rs" <<'RUST'
#[cfg(test)]
mod raw_tests;
#[cfg(test)]
fn helper() {}

fn start() {
    let _ = std::thread::Builder::new().name("x".into()).spawn(|| {});
}
RUST
  if out="$(scan "$dir")"; then
    echo "self-test: a raw site was not reported" >&2
    return 1
  fi
  if [[ "$out" != "cmux-tui/crates/cmux-holder/src/holder/raw.rs:7: "* ]]; then
    echo "self-test: wrong report: $out" >&2
    return 1
  fi
  echo "qos_sites self-test: ok"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if scan "$repo"; then
  echo "qos_sites: every Q12 thread start declares its QoS"
else
  exit 1
fi
