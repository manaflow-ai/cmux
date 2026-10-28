# shellcheck shell=bash
# The Swift -D flags every cmux NEXT Nightly (track nightly-next) adds to OTHER_SWIFT_FLAGS
# (.github/workflows/nightly.yml), and that check-release-compile.sh --nightly compiles with.
#   CMUX_BLOCKING_CHECKS: the main-thread blocking detector records each new blocking call site once
#   (never traps; one public unified-log line of kind + image UUID + offset frames, BlockingLogSink),
#   plans/cmux-next/threading-model.md. Release (the stable channel) compiles it out.
# shellcheck disable=SC2034 # read by the scripts that source this file
CMUX_NIGHTLY_NEXT_SWIFT_DEFINES="-DCMUX_BLOCKING_CHECKS"
