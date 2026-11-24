#!/usr/bin/env bash
# The App Store shelf check: every Discover listing installs and shows something (no pane, web page, native
# page or placed widget tile after install fails it). Run from the repository root with the cmux-tui Rust
# toolchain and the ghostty-next submodule set up. Both callers run it: .github/workflows/app-store-shelf.yml
# (pull requests and pushes touching the shelf) and nightly.yml check-nightly-app-store-shelf (the exact build
# commit of every NEXT nightly, which publishes nothing unless it passes). Leo, 2026-11-16: "if i click install
# it means it works". The tests: cmux-tui/crates/cmux-tui/tests/cli/apps_store.rs.
set -euo pipefail
log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shelf.log"
cd cmux-tui
cargo test --locked -p cmux-tui --test cli -- \
  every_shipped_store_listing_installs_and_has_something_to_open \
  a_command_only_store_listing_has_nothing_to_open_after_install \
  a_first_party_store_app_built_into_the_store_folder_is_listed_not_installed \
  --test-threads=1 2>&1 | tee "$log"
# A filter that matches nothing passes with 0 tests: that judged nothing.
grep -Eq 'test result: ok\. 3 passed' "$log" || {
  echo "::error title=App Store shelf::expected the 3 shelf tests to run and pass"; exit 1; }
