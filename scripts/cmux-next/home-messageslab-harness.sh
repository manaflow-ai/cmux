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
#       OUT, then its `--coverage-check` (OUT/coverage.json: a send while
#       scrolled up leaves no gap and every outgoing bubble keeps its fill).
#       Needs Xcode 27 (the upstream sources use the macOS 27 SDK).
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
#            animations.ndjson byte-identical, plus diff.py's geometry report;
#         3. MessagesLab's coverage check (appkit-native FlashCheck.swift,
#            copied the same way) on the Home path: HomeStore snapshots
#            through the adapter for --coverage-check's script (a send while
#            scrolled up 500 pt, then one at the bottom), every 120 Hz frame.
set -euo pipefail
repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"

case "${1:-}" in
oracle)
  src="$2"; out="$3"
  build="$(mktemp -d)"
  app="$build/MessagesLabAppKitNative.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  files=( "$src"/appkit-native/Sources/*.swift )
  for f in Model Engine PagedSource Pager Layout Transcript Recycler RowDrawing Springs Morph Shapes Fixture Header WindowView Replay \
           ComposeAttachments LinkPreviews; do
    # ComposeAttachments and LinkPreviews exist from MessagesLab 2f22022 / cd2bc08 on.
    [[ -f "$src/catalyst/Sources/$f.swift" ]] && files+=( "$src/catalyst/Sources/$f.swift" )
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
  echo "oracle: $out/animations.ndjson ($(wc -l < "$out/animations.ndjson") transitions)"
  if grep -q "runCoverage" "$src/appkit-native/Sources/FlashCheck.swift" 2>/dev/null; then
    "$app/Contents/MacOS/MessagesLabAppKitNative" -ApplePersistenceIgnoreState YES --coverage-check "$out/coverage.json" | grep coverage-check || true
  fi
  rm -rf "$build"
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
    if [[ -f "$ml/appkit-native/Sources/FlashCheck.swift" ]]; then
      { echo "@testable import MessagesLabHome"; cat "$ml/appkit-native/Sources/FlashCheck.swift"; } > "$up/FlashCheck.swift"
      # LiveProbes (tools/diff-harness/LiveProbes.swift) drives live probes; the check only writes JSON.
      grep -q "enum LiveProbes" "$up/Harness.swift" || cat >> "$up/FlashCheck.swift" <<'SWIFT'
enum LiveProbes {
    static func write(_ obj: Any, _ path: String) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }
}
SWIFT
      cp "$pkg/Harness/HomeCoverageCheck.swift" "$up/HomeCoverageCheck.swift"
    fi
    (cd "$pkg" && MESSAGESLAB_FIXTURES="$out/fixtures" MESSAGESLAB_HARNESS_OUT="$out/vendored" swift test --filter UpstreamHarnessTests)
    if [[ -f "$up/HomeCoverageCheck.swift" ]]; then
      if (cd "$pkg" && MESSAGESLAB_FIXTURES="$out/fixtures" HOME_COVERAGE_OUT="$out/home-coverage.json" swift test --skip-build --filter HomeCoverageCheck); then
        echo "home path coverage: $(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['gapFrames'], 'gap frames,', d['unfilledRowFrames'], 'unfilled bubble-frames')" "$out/home-coverage.json")"
      else
        echo "home path coverage: FAILED ($out/home-coverage.json)"; status=1
      fi
    fi
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
