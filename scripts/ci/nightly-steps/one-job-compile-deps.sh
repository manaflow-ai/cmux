#!/usr/bin/env bash
# nightly.yml nightly-next-one: "Install compilation dependencies", as build-nightly-app's step but without a second
# download of ghostty-next's Zig (20 s in run 43395323737): the one job's "Install Zig" already installed it and
# published CMUX_VT_ZIG. A job where it is missing installs it as build-nightly-app does.
set -euo pipefail
./scripts/install-rust-ci.sh
if [ -x "${CMUX_VT_ZIG:-}" ]; then
  echo "ghostty-next's Zig is already installed: $CMUX_VT_ZIG ($("$CMUX_VT_ZIG" version))"
else
  # ghostty-next's Zig for an in-tree acpmux build (app-build-in-tree-acpmux.sh), as refresh-compilation-cache
  GHOSTTY_ZIG_SOURCE=ghostty-next ZIG_FORCE_LOCAL_INSTALL=1 ZIG_PUBLISH_ENV=CMUX_VT_ZIG ./scripts/install-zig-ci.sh
fi
./scripts/download-prebuilt-ghosttykit.sh
