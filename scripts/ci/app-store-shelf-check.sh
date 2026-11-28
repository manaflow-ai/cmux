#!/usr/bin/env bash
# The App Store shelf check: every Discover listing installs and shows something (no pane, web page, native
# page or placed widget tile after install fails it). Run from the repository root with the cmux-tui Rust
# toolchain and the ghostty-next submodule set up. Both callers run it: .github/workflows/app-store-shelf.yml
# (pull requests and pushes touching the shelf) and nightly.yml check-nightly-app-store-shelf (the exact build
# commit of every NEXT nightly, which publishes nothing unless it passes). Leo, 2026-11-16: "if i click install
# it means it works". The tests: cmux-tui/crates/cmux-tui/tests/cli/apps_store.rs.
set -euo pipefail
log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shelf.log"
# No debug info and no incremental cache: the test build of cmux-tui with full debug info filled the Linux
# runner (nightly-next runs 45607031207 and 45627136798, 2026-11-25: "No space left on device" writing
# target/debug/deps), so the shelf went red, the publication gate refused the build, and the nightly feed sat
# on one build for hours. Leo: "are nightlies not publishin? where the priority?" A test failure still prints
# its panic message and line; only a backtrace loses its source lines.
#
# Warm first: the last feat-cmux-next push's cmux_next_ daemon-tests build (scripts/ci/cmux-tui-test-target.sh, read
# only; a miss builds cold), in that build's env word for word, since its fingerprints hold it. Cold, this step compiled
# 660 crates for 12m53s of a 13.3 min job (job 140527060347, #61750's head, the goal ios-ci-under-5min's second slowest
# check). On a hit, the workspace crates keep the profile's line-tables debug info, as the saved build has: forcing 0
# would rebuild all of them. The saved target is at most 14 GiB, and the restore needs 30 GiB free, so the disk guard
# above still applies to a cold build.
export CARGO_NET_RETRY=10 CARGO_HTTP_TIMEOUT=120 CARGO_HTTP_MULTIPLEXING=false CMUX_GHOSTTY_SRC=""
export GHOSTTY_ZIG_SOURCE=ghostty-next CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
unset CMUX_ZIG ZIG
cd cmux-tui
restore_log="$(mktemp)"
../scripts/ci/cmux-tui-test-target.sh restore 2>&1 | tee "$restore_log" || true
if ! grep -q 'test target: hit' "$restore_log"; then
  export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}" CARGO_PROFILE_TEST_DEBUG="${CARGO_PROFILE_TEST_DEBUG:-0}"
fi
rm -f "$restore_log"
build_start=$SECONDS
cargo test --locked -p cmux-tui --test it -- \
  every_shipped_store_listing_installs_and_has_something_to_open \
  a_command_only_store_listing_has_nothing_to_open_after_install \
  a_first_party_store_app_built_into_the_store_folder_is_listed_not_installed \
  --test-threads=1 2>&1 | tee "$log"
echo "app store shelf: cargo build and test $((SECONDS - build_start)) s, $(grep -cE '^ +Compiling ' "$log" || true) crates compiled"
# A filter that matches nothing passes with 0 tests: that judged nothing.
grep -Eq 'test result: ok\. 3 passed' "$log" || {
  echo "::error title=App Store shelf::expected the 3 shelf tests to run and pass"; exit 1; }
