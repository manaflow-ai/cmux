#!/usr/bin/env bash
# The MessagesLab differential harness for the cmux-next Mac Home tab
# (Packages/Shared/CmuxMessagesLab). Run it on cmux-lawrence-2 or a fleet
# Mac, never on a laptop (it renders offscreen with AppKit).
#
#   home-messageslab-harness.sh oracle MESSAGESLAB_DIR OUT
#       Builds MessagesLabAppKitNative from MESSAGESLAB_DIR (a `git archive`
#       of the pinned commit, vendor.tsv) with swiftc and the
#       flags of appkit-native/project.yml (Swift 5, APPKIT_NATIVE, -Onone like
#       the test build), and writes its `--diff-harness` run (no pixels) to
#       OUT. Needs Xcode 27 (the upstream sources use the macOS 27 SDK).
#
#   home-messageslab-harness.sh compare OUT [ORACLE_OUT MESSAGESLAB_DIR]
#       From the cmux checkout: runs the harness suites, each in its own
#       process (swift test), and compares:
#         1. OUT/home: the Home path (HomeStore snapshots -> adapter) against
#            MessagesLab's actions for send, delivered, read, typing, receive,
#            external insert and tapback: animations.ndjson must be identical
#            (the test also checks every visible layer of every tick);
#         2. with ORACLE_OUT and MESSAGESLAB_DIR: MessagesLab's own harness
#            (tools/diff-harness/Harness.swift from MESSAGESLAB_DIR, copied
#            for this run only into the gitignored Tests/.../Upstream, never
#            vendored) on the vendored files, against the upstream app's run:
#            animations.ndjson byte-identical, plus diff.py's geometry report.
set -euo pipefail
repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"

case "${1:-}" in
oracle)
  src="$2"; out="$3"
  build="$(mktemp -d)"
  app="$build/MessagesLabAppKitNative.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  files=( "$src"/appkit-native/Sources/*.swift )
  for f in Model Engine PagedSource Pager Layout Transcript Recycler RowDrawing Springs Morph Shapes Fixture Header WindowView Replay; do
    files+=( "$src/catalyst/Sources/$f.swift" )
  done
  files+=( "$src"/appkit-port/Sources/Shim/{UIKitNames,RoundedRect,LayerViews}.swift "$src"/tools/diff-harness/{Harness,LiveProbes}.swift )
  xcrun swiftc -swift-version 5 -Onone -D APPKIT_NATIVE -target arm64-apple-macos26.0 -lsqlite3 \
    -module-name MessagesLabAppKitNative -o "$app/Contents/MacOS/MessagesLabAppKitNative" "${files[@]}"
  cp "$src/catalyst/springs.json" "$src/shared/conversation.json" "$app/Contents/Resources/"
  cp -R "$src/shared/assets" "$app/Contents/Resources/assets"
  cp -R "$src/catalyst/Fixtures/real" "$app/Contents/Resources/real"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MessagesLabAppKitNative</string>
<key>CFBundleIdentifier</key><string>com.cmux.prototype.MessagesLab.appkit-native.oracle</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  mkdir -p "$out"
  # The harness runs offscreen on a virtual clock and exits; no window.
  "$app/Contents/MacOS/MessagesLabAppKitNative" -ApplePersistenceIgnoreState YES --diff-harness "$out" --no-pixels
  rm -rf "$build"
  echo "oracle: $out/animations.ndjson ($(wc -l < "$out/animations.ndjson") transitions)"
  ;;
compare)
  out="$2"; oracle="${3:-}"
  pkg="$repo/Packages/Shared/CmuxMessagesLab"
  mkdir -p "$out"
  (cd "$pkg" && swift build --build-tests >/dev/null)
  (cd "$pkg" && HOME_HARNESS_OUT="$out/home" swift test --skip-build --filter HomeHarnessTests)
  status=0
  if cmp -s "$out/home/messageslab/animations.ndjson" "$out/home/home/animations.ndjson"; then
    echo "home path: animations.ndjson identical to MessagesLab's ($(wc -l < "$out/home/home/animations.ndjson") transitions)"
  else
    echo "home path: animations.ndjson DIFFERS"; status=1
  fi
  if [[ -n "$oracle" ]]; then
    ml="$4"
    up="$pkg/Tests/MessagesLabHomeTests/Upstream"
    trap 'rm -rf "$up"' EXIT
    mkdir -p "$up" "$out/fixtures"
    { echo "@testable import MessagesLabHome"; cat "$ml/tools/diff-harness/Harness.swift"; } > "$up/Harness.swift"
    cp "$ml/shared/conversation.json" "$out/fixtures/"
    cp -R "$ml/shared/assets" "$out/fixtures/assets"
    cp -R "$ml/catalyst/Fixtures/real" "$out/fixtures/real"
    cat > "$up/UpstreamRun.swift" <<'SWIFT'
import Foundation
import Testing
@testable import MessagesLabHome

@MainActor @Suite struct UpstreamHarnessTests {
    @Test func messagesLabsScriptOnTheVendoredCode() {
        let env = ProcessInfo.processInfo.environment
        Fixtures.root = URL(fileURLWithPath: env["MESSAGESLAB_FIXTURES"]!)
        DiffHarness.runOffscreen(outDir: env["MESSAGESLAB_HARNESS_OUT"]!, arguments: ["--no-pixels"])
    }
}
SWIFT
    (cd "$pkg" && MESSAGESLAB_FIXTURES="$out/fixtures" MESSAGESLAB_HARNESS_OUT="$out/vendored" swift test --filter UpstreamHarnessTests)
    if cmp -s "$oracle/animations.ndjson" "$out/vendored/animations.ndjson"; then
      echo "vendored: animations.ndjson byte-identical to MessagesLabAppKitNative ($(wc -l < "$oracle/animations.ndjson") transitions)"
    else
      echo "vendored: animations.ndjson DIFFERS from MessagesLabAppKitNative"; status=1
    fi
    python3 "$ml/tools/diff-harness/diff.py" "$oracle" "$out/vendored" --md "$out/vendored-report.md" --json "$out/vendored-report.json" || true
    echo "report: $out/vendored-report.md"
  fi
  exit $status
  ;;
*)
  sed -n '2,25p' "$0"; exit 2 ;;
esac
