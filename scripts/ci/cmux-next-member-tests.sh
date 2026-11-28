#!/usr/bin/env bash
# One big member's cmux_next_ daemon tests on the pull request: ci/steps.toml's cmux-next-acpmux,
# cmux-next-tui-core and cmux-next-tui steps. The same cargo test the post-merge gate (cmux-next-daemon-tests) runs for
# that member, with the gate's build env, so the gate's saved target (scripts/ci/cmux-tui-test-target.sh, from the last
# feat-cmux-next push) is fresh here and only what the pull request changed compiles.
#
#   scripts/ci/cmux-next-member-tests.sh MEMBER_DIR     (MEMBER_DIR under cmux-tui/, e.g. crates/acpmux)
#   scripts/ci/cmux-next-member-tests.sh MEMBER_DIR TEST FILTER
#                                         one of the member's gate test targets only, and only the gate tests whose
#                                         path holds FILTER (FILTER starts within cmux_next_'s module path, e.g.
#                                         `it idle_wakeups::cmux_next_`: ci/steps.toml cmux-next-idle-wakeups)
#
# Fails when a test fails, when nothing compiles, and when the filter runs no test (as the gate does). A recognized
# Cargo fetch failure is retried twice, as in the gate.
set -euo pipefail
member="${1:?usage: $0 MEMBER_DIR [TEST FILTER]}"
only_test="${2:-}"
filter="${3:-cmux_next_}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo/cmux-tui"
read -r -a args <<<"$(../scripts/ci/cmux-next-daemon-test-packages.sh "$member")"
if [[ -n "$only_test" ]]; then
  # The gate's own target only, so the gate's saved target covers it and a red here is a red there.
  [[ " ${args[*]} " == *" --test $only_test "* ]] || { echo "::error::$member's gate targets (${args[*]}) have no --test $only_test"; exit 2; }
  [[ "$filter" == *cmux_next_* ]] || { echo "::error::filter $filter selects tests the gate does not run (it holds no cmux_next_)"; exit 2; }
  args=("${args[0]}" "${args[1]}" --test "$only_test")
fi
# Select the gate's packages, not the member's alone: cargo resolves features over the packages one command names, and
# one member alone gives 27 (cmux-tui), 67 (cmux-tui-core) or 82 (acpmux) crates, proc-macro2 (span-locations), syn
# and num-traits among them, other features than the gate's 10-package command, other hashes, so a "hit" on the gate's
# saved target still rebuilt it: cargo test took 1665-2410 s (cmux-tui `it`, 46 landing heads in 6 h, 2026-11-28
# 05-11Z, 1,768 runner-min; jobs 140885307870, 140948193539), 2162 s (cmux-tui, job 140926948698), 1613-1620 s
# (cmux-tui-core, jobs 140926948698, 140911041297) and 1048 s (acpmux, job 140900588167).
pkg="${args[1]}"
targets=("${args[@]:2}")
read -r -a gate <<<"$(../scripts/ci/cmux-next-daemon-test-packages.sh)"
selected=()
for ((i = 0; i < ${#gate[@]}; i++)); do
  case "${gate[i]}" in
    -p) selected+=(-p "${gate[i + 1]}"); i=$((i + 1)) ;;
    --workspace) selected+=(--workspace) ;;
  esac
done
[[ " ${selected[*]} " == *" -p $pkg "* ]] || selected=(-p "$pkg")
args=("${selected[@]}" "${targets[@]}")
# `--test NAME` builds only the selected packages that declare NAME (`it` is cmux-tui's alone), so cargo test runs the
# member's tests. `--lib`/`--bins` would select every package's, so then the gate's packages build (--no-run) and only
# the member's test binaries run, as cargo test runs them: from the member's directory, with its CARGO_* env.
lone=1
[[ " ${targets[*]} " == *" --lib "* || " ${targets[*]} " == *" --bins "* ]] && [[ ${#selected[@]} -gt 2 ]] && lone=0
member_tests() {
  if [ "$lone" -eq 1 ]; then cargo test "${args[@]}" --locked "$filter"; return; fi
  local built rc=0
  built="$(mktemp /tmp/cmux-next-member-build.XXXXXX.json)"
  cargo test "${args[@]}" --locked --no-run --message-format=json-render-diagnostics >"$built" || rc=$?
  if [ "$rc" -eq 0 ]; then
    while IFS=$'\t' read -r version exe; do
      echo "     Running $exe"
      (cd "$repo/cmux-tui/$member" && CARGO="$(command -v cargo)" CARGO_MANIFEST_DIR="$PWD" CARGO_PKG_NAME="$pkg" \
        CARGO_PKG_VERSION="$version" CARGO_CRATE_NAME="${pkg//-/_}" "$exe" "$filter") || { rc=$?; break; }
    done < <(python3 -I - "$built" "$repo/cmux-tui/$member/Cargo.toml" <<'EOF'
import json, sys
manifest = sys.argv[2]
for line in open(sys.argv[1]):
    m = json.loads(line) if line.startswith("{") else {}
    if m.get("reason") == "compiler-artifact" and m.get("executable") and m["profile"]["test"] and m["manifest_path"] == manifest:
        print(m["package_id"].rsplit("@", 1)[-1], m["executable"], sep="\t")
EOF
    )
  fi
  rm -f "$built"
  return "$rc"
}
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
  # set -e would end the script on a failing pipeline: keep it off for the test so the retry, the timing line and the
  # daemon cleanup below still run.
  set +e
  member_tests 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e
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
