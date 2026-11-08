#!/usr/bin/env bash
# Prints the architectures the CI Release check compiles.
#
# The shipped app is always universal, and nightly.yml builds it that way on
# every main revision. This only sizes the pre-merge Release check in ci.yml:
# `arm64` skips the Intel whole-module compile there, so an Intel-only compile
# break is caught by the nightly build after merge instead of before it.
set -euo pipefail

requested="${1:-}"
case "$requested" in
  ""|default|universal) echo "arm64 x86_64" ;;
  arm64) echo "arm64" ;;
  *)
    echo "error: unsupported Release check architectures '$requested' (expected universal or arm64)" >&2
    exit 1
    ;;
esac
