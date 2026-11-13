# shellcheck shell=bash
# Release Swift is compiled for size (-Osize), except the targets on a per-frame or per-keystroke path,
# which keep -O. Source it, then:
#   swift_size_opt_xcodebuild_args   the settings, one argument per line, for a Release xcodebuild
#
# MacOS/cmux was 154 MiB against its 104 MB cap (scripts/cmux-next/bundle-size-budget.json), and about
# 100 MB of its 123.5 MB __text is Swift (nightly 4318547490101, cmux-symbols.bin grouped by module;
# plans/cmux-next/bundle-size-DESIGN.md cut 10). -Osize keeps the -O pipeline but does not inline or
# specialize to trade size for speed.
#
# The settings apply to every Swift target the build compiles (the app, its packages, third-party Swift),
# the same way the live code build sets its per-target optimization (scripts/live-code/lib/xcodebuild-args.sh).
# A live code build does not use these: its own SWIFT_OPTIMIZATION_LEVEL decides.

# Targets that run per frame, per keystroke or per daemon message: they keep -O.
swift_size_opt_hot_targets() {
  printf '%s\n' \
    CmuxNextTerminal \
    CmuxNextTerminalGeometry \
    CmuxNextTerminalFind \
    CmuxNextCopyMode \
    CmuxNextTabs \
    CmuxNextSidebar \
    CmuxNextLayout \
    CmuxNextPalette \
    CmuxNextDaemon \
    CmuxNextAgentPane \
    CmuxNextBrowserCore \
    CmuxNextBrowserHost \
    CmuxNextFocus \
    CmuxNextDesignTokens \
    CmuxNextBridge \
    CmuxNextPages
}

swift_size_opt_xcodebuild_args() {
  local target
  # shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
  printf '%s\n' 'SWIFT_OPTIMIZATION_LEVEL=$(CMUX_SWIFT_OPT_$(TARGET_NAME):default=-Osize)'
  while IFS= read -r target; do
    printf '%s\n' "CMUX_SWIFT_OPT_$target=-O"
  done < <(swift_size_opt_hot_targets)
}
