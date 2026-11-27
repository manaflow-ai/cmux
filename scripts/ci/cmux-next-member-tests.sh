#!/usr/bin/env bash
# One big member's cmux_next_ daemon tests on the pull request: ci/steps.toml's cmux-next-acpmux,
# cmux-next-tui-core and cmux-next-tui steps. The same cargo test the post-merge gate (cmux-next-daemon-tests) runs for
# that member, with the gate's build env, so the gate's saved target (scripts/ci/cmux-tui-test-target.sh, from the last
# feat-cmux-next push) is fresh here and only what the pull request changed compiles.
#
#   scripts/ci/cmux-next-member-tests.sh MEMBER_DIR     (MEMBER_DIR under cmux-tui/, e.g. crates/acpmux)
#
# Fails when a test fails, when nothing compiles, and when the filter runs no test (as the gate does). A recognized
# Cargo fetch failure is retried twice, as in the gate.
set -euo pipefail
member="${1:?usage: $0 MEMBER_DIR}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo/cmux-tui"
read -r -a args <<<"$(../scripts/ci/cmux-next-daemon-test-packages.sh "$member")"
channel="$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' rust-toolchain.toml)"
rustup toolchain install "$channel" --profile minimal --component clippy,rustfmt
# cmux-next-daemon-tests' env, word for word: the saved target's fingerprints hold it.
export CARGO_NET_RETRY=10 CARGO_HTTP_TIMEOUT=120 CARGO_HTTP_MULTIPLEXING=false TMPDIR=/tmp CMUX_GHOSTTY_SRC=""
export GHOSTTY_ZIG_SOURCE=ghostty-next CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=2
unset CMUX_ZIG ZIG
../scripts/ci/cmux-tui-test-target.sh restore
home="$(mktemp -d /tmp/acpmux-home.XXXXXX)"
export ACPMUX_HOME="$home" ACPMUX_SOCKET=""
log="$(mktemp /tmp/cmux-next-member-tests.XXXXXX.txt)"
echo "cmux_next_ tests of $member: ${args[*]}"
start=$SECONDS
status=1
for attempt in 1 2 3; do
  cargo test "${args[@]}" --locked cmux_next_ 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  if [ "$status" -ne 0 ] && python3 ../scripts/cmux-next/cargo-locks.py explain "$log"; then break; fi
  if [ "$status" -eq 0 ]; then
    grep -qE 'test result: ok\. [1-9][0-9]* passed' "$log" && break
    echo "::error::cargo test ran no cmux_next_ test of $member (the filter matched nothing)"
    status=1
    break
  fi
  if grep -qE 'test result: FAILED|error(\[E[0-9]+\])?: could not compile|^error\[E[0-9]+\]' "$log" \
    || ! grep -qiE 'spurious network error|failed to download|unable to update registry|failed to (fetch|get|query)|could not resolve host|couldn.t resolve host|connection (reset|refused|timed out)|operation timed out|ssl (connect )?error|http2 error|early eof|download of .* failed|registry index .*(failed|error)' "$log"; then
    echo "::error::cmux_next_ tests of $member failed with a result that is not a Cargo fetch failure; not retrying"
    break
  fi
  [ "$attempt" -lt 3 ] && sleep $((attempt * 10))
done
echo "cmux_next_ tests of $member: cargo test took $((SECONDS - start)) s (exit $status)"
case "$(head -c 300 "$(command -v cargo)" 2>/dev/null | tr -d '\0')" in
  *RUSTC_WRAPPER=*sccache*) sccache --show-stats || true ;;
esac
# End the daemon of this home and its agents, then delete the home (a path this script made).
acpmux="$(command -v acpmux || true)"
[ -z "$acpmux" ] || env -u ACPMUX_SOCKET ACPMUX_HOME="$home" "$acpmux" daemon shutdown --end-agents || true
rm -rf "$home" "$log"
exit "$status"
