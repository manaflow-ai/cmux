#!/usr/bin/env bash
# Exercise runner arguments and actual command/env forwarding without building or loading a host.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/scripts/measure" "$root/scripts/cmux-next/lib" "$root/cmux-tui" "$tmp/bin"
cp "$repo/scripts/measure/rust-test-bench.sh" "$root/scripts/measure/"
cp "$repo/scripts/cmux-next/lib/fleet-only.sh" "$root/scripts/cmux-next/lib/"
: >"$root/cmux-tui/Cargo.toml"
cat >"$tmp/bin/cargo" <<'SH'
#!/bin/bash
printf '%s | enable=%s legs=%s\n' "$*" "${ACPMUX_DURESS:-unset}" "${ACPMUX_DURESS_LEGS:-unset}" >>"$CALLS_LOG"
[[ " $* " != *" --no-run "* ]] || exit 0
if [[ "${ACPMUX_DURESS:-}" == 1 && "${MOCK_REPORT:-yes}" == yes ]]; then
  printf '{"schema":"acpmux.duress-bench.v1"}\n' >"$FAST_CHECKS_OUT/duress-bench.json"
  printf '# measured\n' >"$FAST_CHECKS_OUT/duress-bench.md"
fi
echo "test result: ok. ${MOCK_RAN:-1} passed; 0 failed; 0 ignored"
exit "${MOCK_STATUS:-0}"
SH
cat >"$tmp/bin/git" <<'SH'
#!/bin/sh
case "$*" in
  'rev-parse HEAD') echo 0123456789abcdef0123456789abcdef01234567 ;;
  'rev-parse --is-shallow-repository') echo false ;;
esac
SH
for tool in sysctl sw_vers go top; do
  printf '#!/bin/sh\necho 1\n' >"$tmp/bin/$tool"
done
chmod +x "$tmp/bin/"*
run() {
  local want=$1 status=0
  shift
  : >"$tmp/calls"
  CALLS_LOG="$tmp/calls" CMUX_CI_STEP_KEY=test PATH="$tmp/bin:$PATH" \
    bash "$root/scripts/measure/rust-test-bench.sh" "$@" >"$tmp/output" 2>&1 || status=$?
  if [[ "$status" != "$want" ]]; then
    cat "$tmp/output"; echo "wanted exit $want, got $status for $*"; exit 1
  fi
}
want() { grep -qF -- "$1" "$tmp/calls" || { cat "$tmp/calls"; echo "missing $1"; exit 1; }; }
duress=(acpmux duress_bench target=test:duress_daemon config=release ignored=1 enable=ACPMUX_DURESS "legs=baseline,rfd0050")
run 0 "${duress[@]}"
want 'test --locked -p acpmux --test duress_daemon --release --no-run | enable=unset legs=unset'
want 'test --locked -p acpmux --test duress_daemon --release -- duress_bench --nocapture --test-threads=1 --ignored | enable=1 legs=baseline,rfd0050'
[[ -s "$root/artifacts/rust-test-bench/duress/duress-bench.json" ]]
# A prior successful artifact cannot satisfy a skipped run.
MOCK_REPORT=no run 1 "${duress[@]}"
run 0 acpmux ordinary target=lib
want 'test --locked -p acpmux --lib -- ordinary --nocapture --test-threads=1 | enable=unset legs=unset'
run 0 acpmux ordinary ignored=1
want '--test-threads=1 --ignored'
MOCK_RAN=0 run 1 acpmux ordinary
MOCK_STATUS=7 run 7 acpmux ordinary
run 2 acpmux ordinary ignored=0
run 2 acpmux ordinary ignored=1 ignored=1
run 2 acpmux ordinary enable=PATH
run 2 acpmux ordinary legs=baseline
run 2 acpmux duress_bench enable=ACPMUX_DURESS
run 2 "${duress[@]}" config=debug
run 2 acpmux duress_bench target=test:duress_daemon config=release ignored=1 enable=ACPMUX_DURESS legs=cpu
echo 'rust-test-bench: arguments, forwarding, fresh reports and failures passed'
