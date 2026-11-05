# shellcheck shell=bash
# The live code build's xcodebuild settings (docs/cmux-next/live-code.md), for any script that runs
# xcodebuild on the app: scripts/reload.sh with CMUX_LIVE_CODE_BUILD=1, and the NIGHTLY live code
# variant's app build. Source it, then:
#   live_code_xcodebuild_args CONFIG [LIST]   the settings, one argument per line
#   live_code_swift_flags                     the Swift flags to add to the build's own
#
# A patch replaces functions of any CmuxNext module (they all link into the one app executable), so
# every CmuxNext target is compiled unoptimized and testable (every function stays a real call with
# an exported symbol), and the app is linked with classic binds, its symbols exported and none
# stripped as unused. Third-party packages keep the configuration's optimization. The log keeps
# each module's frontend command, which a patch is compiled with (scripts/live-code/patch.py).
# Interposable are only the symbols LIST names (the app's exported Swift symbols that name a
# CmuxNext module, from a first link: lib/two-pass.sh). A blanket `-interposable` also routes a
# whole-module build's hidden symbols (a file's private types, global across the module's object
# files but never exported) through dyld, which cannot find them, and the app does not launch. The
# CmuxNext targets are compiled a file at a time for the same reason.

live_code_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every CmuxNext target Package.swift names (products and tests too; a name no target has is
# never read).
live_code_targets() {
  grep -oE 'name: "CmuxNext[A-Za-z0-9_]*"' "$live_code_lib_dir/../../../Packages/macOS/CmuxNext/Package.swift" \
    | sed -E 's/.*"(.*)"/\1/' | sort -u
}

live_code_xcodebuild_args() { # CONFIG [LIST]
  local config="$1" list="${2:-}" mode=wholemodule target
  [[ "$config" == "Debug" ]] && mode=singlefile
  local ldflags='$(inherited) -Xlinker -no_fixup_chains'
  [[ -n "$list" ]] && ldflags+=" -Xlinker -interposable_list -Xlinker $list"
  # shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
  printf '%s\n' \
    EMIT_FRONTEND_COMMAND_LINES=YES \
    'SWIFT_OPTIMIZATION_LEVEL=$(CMUX_LIVE_CODE_OPT_$(TARGET_NAME):default=-O)' \
    'ENABLE_TESTABILITY=$(CMUX_LIVE_CODE_TESTABLE_$(TARGET_NAME):default=NO)' \
    "SWIFT_COMPILATION_MODE=\$(CMUX_LIVE_CODE_MODE_\$(TARGET_NAME):default=$mode)" \
    LD_EXPORT_SYMBOLS=YES \
    DEAD_CODE_STRIPPING=NO \
    "OTHER_LDFLAGS=$ldflags"
  while IFS= read -r target; do
    printf '%s\n' "CMUX_LIVE_CODE_OPT_$target=-Onone" "CMUX_LIVE_CODE_TESTABLE_$target=YES" "CMUX_LIVE_CODE_MODE_$target=singlefile"
  done < <(live_code_targets)
}

# CMUX_LIVE_CODE compiles the watcher in outside Debug and bench (a NIGHTLY live code build), where
# it loads only patches signed by the app's own team (CmuxNextLiveCode/PatchSignature.swift).
live_code_swift_flags() {
  printf '%s\n' "-DCMUX_LIVE_CODE"
}
