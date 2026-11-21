# shellcheck shell=bash
# The live code build's xcodebuild settings (docs/cmux-next/live-code.md), for any script that runs
# xcodebuild on the app: scripts/reload.sh with CMUX_LIVE_CODE_BUILD=1, and the NIGHTLY live code
# variant's app build. Source it, then:
#   live_code_xcodebuild_args CONFIG [LIST]   the settings, one argument per line
#   live_code_swift_flags                     the Swift flags to add to the build's own
#   live_code_copy_resource_bundles APP       after the build: the package resource bundles into APP
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
# never read), and the shared modules it links that a patch may edit as well:
# CMUX_LIVE_CODE_SHARED_MODULES, by default MessagesLabHome (the Home transcript, vendored in
# Packages/Shared/CmuxMessagesLab), named only while Package.swift links it. Set it empty to build
# them optimized again. live_apply.py LIVE_MODULE sorts their Swift as patchable.
live_code_shared_modules() {
  local package="$live_code_lib_dir/../../../Packages/macOS/CmuxNext/Package.swift" module
  for module in ${CMUX_LIVE_CODE_SHARED_MODULES-MessagesLabHome}; do
    grep -q "product(name: \"$module\"" "$package" && printf '%s\n' "$module"
  done
  return 0
}

live_code_targets() {
  { grep -oE 'name: "CmuxNext[A-Za-z0-9_]*"' "$live_code_lib_dir/../../../Packages/macOS/CmuxNext/Package.swift" \
      | sed -E 's/.*"(.*)"/\1/'
    live_code_shared_modules; } | sort -u
}

# A grep -E pattern for the module names a patch may edit, as Swift mangles them (length, then name).
live_code_module_pattern() {
  local shared
  shared="$(live_code_shared_modules | paste -sd '|' -)"
  printf '%s\n' "[0-9](CmuxNext${shared:+|$shared})"
}

live_code_xcodebuild_args() { # CONFIG [LIST]
  local config="$1" list="${2:-}" mode=wholemodule target
  [[ "$config" == "Debug" ]] && mode=singlefile
  # -no_deduplicate: ld folds functions with identical code into one (Xcode turns that off only in
  # Debug). A fold leaves a private symbol at the address of another function, and references to it
  # then bind by name through dyld, which finds no such export and stops the launch (a Release live
  # code build bound hundreds: two private classes' deinits at one address). Live code also needs
  # every function at its own address, or a patch to one repoints all the code folded with it.
  local ldflags='$(inherited) -Xlinker -no_fixup_chains -Xlinker -no_deduplicate'
  # Quoted: Xcode splits OTHER_LDFLAGS on spaces, and a fleet checkout sits under
  # "/Library/Application Support".
  [[ -n "$list" ]] && ldflags+=" -Xlinker -interposable_list -Xlinker \"$list\""
  # shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
  # EXCLUDED_SOURCE_FILE_NAMES: Package.swift links CmuxNextApp statically into the app here (one
  # image to repoint), so the build makes no CmuxNextApp framework, and the app target's Embed
  # Frameworks phase (cmux.xcodeproj, CE7A00000000000000000047) stopped the build copying it
  # (cmux#48325). Excluding the name skips that copy; the regular build embeds it as before. Xcode
  # then copies none of the package resource bundles into the app either: after the build, the
  # caller runs live_code_copy_resource_bundles.
  printf '%s\n' \
    EMIT_FRONTEND_COMMAND_LINES=YES \
    'EXCLUDED_SOURCE_FILE_NAMES=$(inherited) CmuxNextApp' \
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

# A live code build links CmuxNextApp statically and skips its embed (live_code_xcodebuild_args), and
# Xcode then copies no package resource bundle (CmuxNext_*.bundle: first-party apps, pages, strings)
# into the app: scripts/cmux-next/check-app-bundle.sh stopped every live code build there. Each
# bundle the build made beside APP replaces the app's copy, as scripts/cmux-next/swap-binary.sh
# places its static build's. The app is signed after this (reload.sh, the nightly's signing).
live_code_copy_resource_bundles() { # APP
  local app="$1" bundle n=0
  local products; products="$(dirname "$app")"
  for bundle in "$products"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    rm -rf "$app/Contents/Resources/$(basename "$bundle")"
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
    n=$((n + 1))
  done
  echo "live code build: copied $n package resource bundles into $app" >&2
}
