#!/usr/bin/env bash
# Behavior test for scripts/lib/rust-targets.sh with a stub rustup on PATH:
# an installed target makes no `rustup target add` call (so no network), a
# missing one is added alone, --toolchain reaches both calls, and a failing add
# is retried a bounded number of times.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/rust-targets-helper.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/rustup" <<'S'
#!/usr/bin/env bash
echo "rustup $*" >>"$CALLS"
if [[ "$1 $2" == "target list" ]]; then
  printf '%s\n' $INSTALLED
  exit 0
fi
if [[ "$1 $2" == "toolchain list" ]]; then
  for t in $TOOLCHAINS; do echo "$t-aarch64-apple-darwin"; done
  exit 0
fi
if [[ "$1 $2" == "toolchain install" ]]; then
  count=$(( $(cat "$CALLS.adds" 2>/dev/null || echo 0) + 1 ))
  echo "$count" >"$CALLS.adds"
  [[ "$count" -gt "${FAIL_ADDS:-0}" ]] || { echo "error: could not download file" >&2; exit 1; }
  exit 0
fi
if [[ "$1 $2" == "target add" ]]; then
  count=$(( $(cat "$CALLS.adds" 2>/dev/null || echo 0) + 1 ))
  echo "$count" >"$CALLS.adds"
  [[ "$count" -gt "${FAIL_ADDS:-0}" ]] || { echo "error: could not download file" >&2; exit 1; }
  exit 0
fi
exit 3
S
chmod +x "$work/bin/rustup"

fail=0
check() { # name, expected exit, expected calls (newline separated), then the helper's arguments
  local name="$1" want_status="$2" want_calls="$3" status=0
  shift 3
  export CALLS="$work/$name.calls"
  : >"$CALLS"
  rm -f "$CALLS.adds"
  (
    # shellcheck source=scripts/lib/rust-targets.sh
    source "$root/scripts/lib/rust-targets.sh"
    "${HELPER_FN:-ensure_rust_targets}" "$@"
  ) >"$work/$name.out" 2>&1 || status=$?
  if [[ "$status" != "$want_status" || "$(cat "$CALLS")" != "$want_calls" ]]; then
    echo "FAIL $name: exit $status (want $want_status), calls:" >&2
    sed 's/^/  /' "$CALLS" >&2
    echo "want:" >&2
    printf '%s\n' "$want_calls" | sed 's/^/  /' >&2
    sed 's/^/  out: /' "$work/$name.out" >&2
    fail=1
  else
    echo "ok $name"
  fi
}

export PATH="$work/bin:$PATH" RUST_TARGETS_BACKOFF=0

INSTALLED="aarch64-apple-darwin x86_64-apple-darwin" FAIL_ADDS=0 \
  check installed 0 "rustup target list --installed" aarch64-apple-darwin x86_64-apple-darwin

INSTALLED="aarch64-apple-darwin" FAIL_ADDS=0 \
  check missing-only 0 "rustup target list --installed
rustup target add x86_64-apple-darwin" aarch64-apple-darwin x86_64-apple-darwin

INSTALLED="aarch64-apple-darwin" FAIL_ADDS=0 \
  check toolchain 0 "rustup target list --toolchain 1.95.0 --installed
rustup target add --toolchain 1.95.0 x86_64-apple-darwin" --toolchain 1.95.0 aarch64-apple-darwin x86_64-apple-darwin

INSTALLED="" FAIL_ADDS=2 \
  check retry-then-succeed 0 "rustup target list --installed
rustup target add aarch64-apple-darwin
rustup target add aarch64-apple-darwin
rustup target add aarch64-apple-darwin" aarch64-apple-darwin

INSTALLED="" FAIL_ADDS=99 \
  check bounded-retries 1 "rustup target list --installed
rustup target add aarch64-apple-darwin
rustup target add aarch64-apple-darwin
rustup target add aarch64-apple-darwin" aarch64-apple-darwin

INSTALLED="" FAIL_ADDS=99 RUST_TARGETS_ATTEMPTS=1 \
  check one-attempt 1 "rustup target list --installed
rustup target add aarch64-apple-darwin" aarch64-apple-darwin

INSTALLED="" FAIL_ADDS=0 \
  check no-targets 0 ""

# ensure_rust_toolchain: an installed toolchain makes no install call (no network); a missing one is
# installed with a bounded retry; asking for a component always installs (rustup adds it).
HELPER_FN=ensure_rust_toolchain TOOLCHAINS="1.95.0 stable" FAIL_ADDS=0 \
  check toolchain-installed 0 "rustup toolchain list" 1.95.0 --profile minimal

HELPER_FN=ensure_rust_toolchain TOOLCHAINS="1.950.0 stable" FAIL_ADDS=1 \
  check toolchain-missing-retried 0 "rustup toolchain list
rustup toolchain install 1.95.0 --profile minimal
rustup toolchain install 1.95.0 --profile minimal" 1.95.0 --profile minimal

HELPER_FN=ensure_rust_toolchain TOOLCHAINS="" FAIL_ADDS=99 \
  check toolchain-bounded 1 "rustup toolchain list
rustup toolchain install 1.95.0
rustup toolchain install 1.95.0
rustup toolchain install 1.95.0" 1.95.0

HELPER_FN=ensure_rust_toolchain TOOLCHAINS="1.95.0" FAIL_ADDS=0 \
  check toolchain-component 0 "rustup toolchain install 1.95.0 --component clippy" 1.95.0 --component clippy

exit "$fail"
