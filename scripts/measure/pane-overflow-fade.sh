#!/usr/bin/env bash
# Native presentation-layer measurement for pane overflow fade. Run only through:
#   cmux-ci run --class exclusive --script scripts/measure/pane-overflow-fade.sh \
#     --ref <published SHA> --label measure --measurement
#
# The script intentionally runs no custom controller kind, host, or inline dispatch payload.
# It selects the landed parent (or a test-first ancestor), then captures the real
# AppKit presentation layer on a console-session measure worker. The source fence is dynamic so
# the product fix can be rebased onto this measurement script PR without editing the proof.
set -euo pipefail
PRODUCT_PATH="Packages/macOS/CmuxNext/Sources/CmuxNextTabs/PaneToolbarView.swift"
REGRESSION_PATH="Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TabBarRestingControlsTests.swift"
EXPECTED_FIXED_BLOB="1b6fd511d3a1491d773c20f4be572c914cd8abba"
EXPECTED_OLD_BLOB="f793324e06a9ee00ebae19730a962b2264416ee1"
EXPECTED_RED_TEST_BLOB="9b58a3b9ee7c3f13bc8abfc144c25e5f0d2a67e9"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
die() { echo "NATIVE_FADE_FATAL $*" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || die "needs managed macOS GUI worker"
git diff --quiet && git diff --cached --quiet || die "source checkout is dirty"
git status --porcelain --untracked-files=no | grep -q . && die "tracked source checkout is dirty" || true
SCRIPT_SHA="$(git rev-parse HEAD)" || die "cannot resolve script HEAD"
SCRIPT_TREE="$(git rev-parse 'HEAD^{tree}')" || die "cannot resolve script tree"
# A tooling follow-up can measure the original landed product commit explicitly.
HEAD_SHA="${1:-$SCRIPT_SHA}"
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || die "measurement ref must be a full commit SHA"
# Cold measure workers are shallow detached checkouts with no origin. Use the
# same canonical repository URL as checkoutStep, without changing their remotes.
SOURCE_REMOTE="$(git remote get-url origin 2>/dev/null || printf '%s' 'https://github.com/manaflow-ai/cmux.git')"
if ! python3 - "$HEAD_SHA" "$SOURCE_REMOTE" <<'PY_FETCH'
import subprocess
import sys

# A depth flag only in an already-shallow checkout: in a developer's full clone it
# would make every worktree sharing the git directory shallow.
is_shallow = subprocess.run(["git", "rev-parse", "--is-shallow-repository"],
                            capture_output=True, text=True, check=False).stdout.strip() == "true"
depth = ["--depth=8"] if is_shallow else []
try:
    result = subprocess.run(
        ["git", "-c", "fetch.parallel=1", "fetch", *depth,
         "--no-tags", "--no-recurse-submodules", sys.argv[2], sys.argv[1]],
        check=False,
        timeout=150,
    )
except subprocess.TimeoutExpired:
    raise SystemExit("bounded source fetch timed out after 150 seconds")
raise SystemExit(result.returncode)
PY_FETCH
then
  die "bounded source fetch failed"
fi
HEAD_TREE="$(git rev-parse "$HEAD_SHA^{tree}")" || die "cannot resolve measured tree"
echo "NATIVE_FADE_PREFLIGHT script=$SCRIPT_SHA script_tree=$SCRIPT_TREE head=$HEAD_SHA tree=$HEAD_TREE"
FIXED_BLOB="$(git rev-parse "$HEAD_SHA:$PRODUCT_PATH")" || die "product path missing"
[ "$FIXED_BLOB" = "$EXPECTED_FIXED_BLOB" ] || die "final product blob mismatch expected=$EXPECTED_FIXED_BLOB actual=$FIXED_BLOB"
[ "$(git rev-parse "$HEAD_SHA:$REGRESSION_PATH")" = "$EXPECTED_RED_TEST_BLOB" ] || die "final regression test blob changed"
PARENT_SHA="$(git rev-parse "$HEAD_SHA^")" || die "final parent unavailable"
TEST_OVERLAY_BLOB=""
if [ "$(git rev-parse "$PARENT_SHA:$PRODUCT_PATH" 2>/dev/null || true)" = "$EXPECTED_OLD_BLOB" ]; then
  # A normal squash has no test-first ancestor. Measure its real parent product,
  # overlaying only the exact final regression so before/after run the same test.
  BEFORE_MODE="parent-with-test-overlay"
  BASE_SHA="$PARENT_SHA"
  RED_SHA="$PARENT_SHA"
  TEST_OVERLAY_BLOB="$EXPECTED_RED_TEST_BLOB"
else
  BEFORE_MODE="red-ancestor"
  RED_SHA="$(git log "$HEAD_SHA" --format='%H' -- "$REGRESSION_PATH" | while read -r candidate; do
    [ "$(git rev-parse "$candidate:$REGRESSION_PATH" 2>/dev/null || true)" = "$EXPECTED_RED_TEST_BLOB" ] || continue
    [ "$(git rev-parse "$candidate:$PRODUCT_PATH" 2>/dev/null || true)" = "$EXPECTED_OLD_BLOB" ] || continue
    printf '%s\n' "$candidate"
    break
  done)"
  [ -n "$RED_SHA" ] || die "red regression commit with expected old test/product blobs not found"
  BASE_SHA="$(git rev-parse "$RED_SHA^")" || die "red parent unavailable"
  [ "$(git rev-parse "$RED_SHA:$REGRESSION_PATH")" = "$EXPECTED_RED_TEST_BLOB" ] || die "red test blob changed"
fi
RED_TREE="$(git rev-parse "$RED_SHA^{tree}")" || die "red tree unavailable"
BASE_TREE="$(git rev-parse "$BASE_SHA^{tree}")" || die "base tree unavailable"
BEFORE_TEST_BLOB="$(git rev-parse "$RED_SHA:$REGRESSION_PATH")" || die "before test path missing"
[ "$(git rev-parse "$RED_SHA:$PRODUCT_PATH")" = "$EXPECTED_OLD_BLOB" ] || die "red product blob changed"
[ "$(git rev-parse "$BASE_SHA:$PRODUCT_PATH")" = "$EXPECTED_OLD_BLOB" ] || die "base product blob changed"
git merge-base --is-ancestor "$RED_SHA" "$HEAD_SHA" || die "red is not an ancestor of final"
IDENTITY_RECEIPT="NATIVE_FADE_IDENTITIES mode=$BEFORE_MODE base=$BASE_SHA base_tree=$BASE_TREE red=$RED_SHA red_tree=$RED_TREE head=$HEAD_SHA head_tree=$HEAD_TREE script=$SCRIPT_SHA script_tree=$SCRIPT_TREE before_test_blob=$BEFORE_TEST_BLOB test_overlay_blob=${TEST_OVERLAY_BLOB:-none}"
echo "$IDENTITY_RECEIPT"
prepare_before_regression() {
  local checkout="$1"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$RED_SHA" ] || die "before checkout source changed"
  [ -n "$TEST_OVERLAY_BLOB" ] || return 0
  git show "$HEAD_SHA:$REGRESSION_PATH" > "$checkout/$REGRESSION_PATH"
  [ "$(git -C "$checkout" hash-object "$REGRESSION_PATH")" = "$TEST_OVERLAY_BLOB" ] || die "regression overlay blob changed"
}
assert_measurement_checkout() {
  local checkout="$1" source="$2"
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$source" ] || die "capture checkout HEAD changed"
  git -C "$checkout" diff --cached --quiet || die "capture checkout index changed"
  if ! git -C "$checkout" diff --quiet -- . ":(exclude)$REGRESSION_PATH"; then
    echo "NATIVE_FADE_TRACKED_MUTATION checkout=$checkout source=$source" >&2
    git -C "$checkout" diff --name-status -- . ":(exclude)$REGRESSION_PATH" >&2
    die "capture changed product or unrelated tracked files"
  fi
  [ "$(git -C "$checkout" hash-object "$REGRESSION_PATH")" = "$EXPECTED_RED_TEST_BLOB" ] || die "capture regression test blob changed"
}
WORK="$(mktemp -d /tmp/nx-ellipsis-fade.XXXXXX)"
OUT="$WORK/out"
mkdir -p "$OUT"
printf '%s\n' "$IDENTITY_RECEIPT" > "$OUT/source-identities.txt"
# Rejected measurements stay rejected, with their partial frames and source
# diagnostics retained so a failed source fence can be diagnosed remotely.
keep_failed_attempt() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    printf 'NATIVE_FADE_FAILED exit=%s\n' "$status" > "$OUT/failure.txt"
    mkdir -p "$ROOT/artifacts"
    tar -czf "$ROOT/artifacts/pane-overflow-fade.tar.gz" -C "$OUT" . || true
  fi
  exit "$status"
}
trap keep_failed_attempt EXIT
cat > "$WORK/PaneMoreFadeFrameProbe.swift" <<'NX_FADE_PROBE'
import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Foundation
import CmuxTheme
import QuartzCore
import Testing

// Managed fleet-only instrumentation. This file is injected into a detached worktree,
// never committed. Every PNG is rendered from the real native presentation layer.
@MainActor @Suite(.serialized) struct PaneMoreFadeFrameProbe {
    struct Sample {
        let milliseconds: Double
        let x: CGFloat
        let opacity: Float
        let image: CGImage
    }

    @Test func captureRealNativeFade() async throws {
        _ = NSApplication.shared
        let settings = DesignSettings.shared
        let original = (settings.animationsEnabled, settings.animationSpeed, settings.disabledAnimationCategories,
                        Motion.reduceMotionOverride, ThemeScope.app.store.input, settings.calmMode)
        settings.animationsEnabled = true
        settings.calmMode = .off
        settings.animationSpeed = .normal
        settings.disabledAnimationCategories.remove(.feedback)
        settings.disabledAnimationCategories.remove(.tabs)
        Motion.reduceMotionOverride = false
        defer {
            settings.animationsEnabled = original.0
            settings.animationSpeed = original.1
            settings.disabledAnimationCategories = original.2
            Motion.reduceMotionOverride = original.3
            _ = ThemeScope.app.store.apply(original.4)
            settings.calmMode = original.5
        }
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NX_FADE_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let label = try #require(ProcessInfo.processInfo.environment["NX_FADE_LABEL"])
        let source = try #require(ProcessInfo.processInfo.environment["NX_FADE_SOURCE"])
        for theme in ["Default", "Soft Blue Light"] {
            for kind in [PaneToolbar.Kind.newTab, .terminal] {
                let name = "\(label)-\(kind == .newTab ? "new-tab" : "terminal")-\(theme == "Default" ? "dark" : "light")"
                try await capture(name: name, theme: theme, kind: kind, source: source, output: output)
            }
        }
    }

    private func capture(name: String, theme: String, kind: PaneToolbar.Kind,
                         source: String, output: URL) async throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        root.wantsLayer = true
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        _ = ThemeScope.app.store.apply(try PaneMoreShotsTests.input(theme))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: try PaneMoreShotsTests.input(theme), animated: false)
        scope.root(root)
        window.appearance = scope.appearance
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1).cgColor }
        let title = NSTextField(labelWithString: kind == .newTab ? "New Tab" : "Terminal")
        title.font = NSFont.systemFont(ofSize: TypeScale.body)
        title.textColor = scope.perform { Palette.textSecondary }
        title.frame = NSRect(x: 12, y: 45, width: 130, height: 20)
        root.addSubview(title)
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        toolbar.update(target: "capture", kind: kind)
        let bar = toolbar.view
        bar.frame = NSRect(x: 160, y: 40, width: 68, height: 30)
        root.addSubview(bar)
        window.orderFrontRegardless()
        try #require(window.screen != nil, "native capture needs an active GUI display")
        try #require(Motion.canAnimate(in: bar), "native capture cannot substitute a snap for a fade")
        root.layoutSubtreeIfNeeded()
        bar.reveal.setPointerInside(true)
        // Let the actual native reveal finish before recording its exit.
        let settle = ContinuousClock.now + .seconds(3)
        while bar.moreButton.layer?.presentation()?.opacity != 1, ContinuousClock.now < settle {
            try await Task.sleep(for: .milliseconds(16))
        }
        root.displayIfNeeded()
        CATransaction.flush()
        let duration = Motion.feedback.duration(.hover)
        try #require(duration > 0)
        let first = CACurrentMediaTime()
        var samples: [Sample] = []
        func sample() throws {
            root.displayIfNeeded()
            CATransaction.flush()
            let layer = try #require(bar.moreButton.layer)
            let shown = layer.presentation() ?? layer
            samples.append(Sample(milliseconds: (CACurrentMediaTime() - first) * 1_000,
                                  x: shown.frame.minX, opacity: shown.opacity,
                                  image: try snapshot(root)))
        }
        try sample()
        bar.reveal.setPointerInside(false)
        let end = ContinuousClock.now + .milliseconds(Int(duration * 1_000) + 100)
        while ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(16))
            try sample()
        }
        try #require(samples.count >= 5)
        try #require(samples.first!.opacity > 0.99 && samples.last!.opacity < 0.01,
                     "capture must include the completely shown and fully hidden endpoints")
        try #require(samples.contains { $0.opacity > 0.01 && $0.opacity < 0.99 },
                     "display did not advance intermediate opacity frames; no valid capture")
        let times = [0, duration * 250, duration * 500, duration * 750, duration * 1_000 + 20]
        let selected = times.map { target in samples.min { abs($0.milliseconds - target) < abs($1.milliseconds - target) }! }
        let sheet = try contactStrip(selected)
        try write(sheet, output.appendingPathComponent("\(name).png"))
        let records = samples.map { ["ms": $0.milliseconds, "x": Double($0.x), "opacity": Double($0.opacity)] }
        let receipt: [String: Any] = ["name": name, "source": source, "fade_ms": duration * 1_000,
                                     "samples": records, "screen": window.screen?.localizedName ?? "",
                                     "native_presentation": true]
        let json = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        try json.write(to: output.appendingPathComponent("\(name).json"))
        print("NATIVE_FADE_CAPTURE \(String(decoding: json, as: UTF8.self))")
    }

    private func snapshot(_ view: NSView) throws -> CGImage {
        let size = view.bounds.size
        let context = try #require(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        try #require(view.layer?.presentation() ?? view.layer).render(in: context)
        return try #require(context.makeImage())
    }

    private func contactStrip(_ samples: [Sample]) throws -> CGImage {
        let width = samples.count * 480, height = 210
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(white: 0.15, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index * 480)
            NSImage(cgImage: sample.image, size: NSSize(width: 480, height: 160))
                .draw(in: NSRect(x: x, y: 50, width: 480, height: 160))
            (String(format: "%.0f ms · x %.2f · α %.2f", sample.milliseconds, Double(sample.x), sample.opacity) as NSString)
                .draw(at: NSPoint(x: x + 12, y: 15),
                      withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: TypeScale.detail, weight: .regular),
                                       .foregroundColor: NSColor.white])
        }
        return try #require(bitmap.cgImage)
    }

    private func write(_ image: CGImage, _ output: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: output)
    }
}
NX_FADE_PROBE
git worktree add --detach "$WORK/before" "$RED_SHA"
git worktree add --detach "$WORK/after" "$HEAD_SHA"
prepare_before_regression "$WORK/before"
assert_measurement_checkout "$WORK/before" "$RED_SHA"
# The old cache installer deletes tracked GENERATED.md placeholders. Use the
# tooling checkout's narrow setup wrapper in both historical checkouts; product,
# test and other tracked-source fences remain unchanged.
export CMUX_WEB_BUNDLES_BUILD="$ROOT/scripts/measure/pane-overflow-bundle-setup.py"
# These worktrees belong to this one attempt; keep them and their receipts on failure.
for label in before after; do
  checkout="$WORK/$label"
  source="$RED_SHA"
  [ "$label" = before ] || source="$HEAD_SHA"
  cp "$WORK/PaneMoreFadeFrameProbe.swift" "$checkout/Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/PaneMoreFadeFrameProbe.swift"
  (
    cd "$checkout"
    export NX_FADE_LABEL="$label" NX_FADE_OUTPUT="$OUT" NX_FADE_SOURCE="$source"
    bash scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext PaneMoreFadeFrameProbe
  ) > "$OUT/$label-capture.log" 2>&1 || { cat "$OUT/$label-capture.log"; echo NATIVE_FADE_CAPTURE_FAILED; exit 1; }
  cat "$OUT/$label-capture.log"
  assert_measurement_checkout "$checkout" "$source"
done
# Run the exact same regression against the old and fixed products. The parent
# mode keeps the old product intact and records its regression-only overlay.
set +e
(cd "$WORK/before" && bash scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext TabBarRestingControlsTests) > "$OUT/red.log" 2>&1
RED_EXIT=$?
set -e
cat "$OUT/red.log"
[ "$RED_EXIT" -ne 0 ] || { echo NATIVE_FADE_EXPECTED_RED_DID_NOT_FAIL; exit 1; }
python3 - "$OUT/red.log" <<'NX_RED_ORACLE'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
if "moreFadesInPlace" not in text or not re.search(r"(must not move it right|never waits outside its hit target)", text):
    raise SystemExit("No specific old slide geometry failure; setup/base failures are not regression evidence")
NX_RED_ORACLE
(cd "$WORK/after" && bash scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext TabBarRestingControlsTests,PaneMoreOverflowButtonTests,PaneChromeEvenInsetTests,TabSelectionKeepsTabWidthsTests) > "$OUT/green.log" 2>&1 || { cat "$OUT/green.log"; exit 1; }
cat "$OUT/green.log"
mkdir -p "$ROOT/artifacts"
tar -czf "$ROOT/artifacts/pane-overflow-fade.tar.gz" -C "$OUT" .
python3 - "$OUT" "$RED_SHA" "$HEAD_SHA" <<'NX_CAPTURE_ORACLE'

import json,pathlib,sys,hashlib,base64
out=pathlib.Path(sys.argv[1])
for label, source in [("before",sys.argv[2]),("after",sys.argv[3])]:
    files=sorted(out.glob(f"{label}-*.json"))
    if len(files)!=4:raise SystemExit(f"Expected4native receipts for {label}, got{len(files)}")
    for file in files:
        data=json.loads(file.read_text()); samples=data["samples"]
        if data["source"]!=source or not data["native_presentation"] or not data["screen"]:
            raise SystemExit(f"Invalid source/display receipt:{file}")
        xs=[s["x"] for s in samples]; alphas=[s["opacity"] for s in samples]
        if alphas[0]<.99 or alphas[-1]>.01 or not any(.01<a<.99 for a in alphas):
            raise SystemExit(f"Missing real fade endpoints/intermediates:{file}")
        movement=max(xs)-min(xs)
        if label=="before" and movement<8:raise SystemExit(f"No before slide witnessed:{file}")
        if label=="after" and movement>.01:raise SystemExit(f"After fade still moves{movement}pt:{file}")
        print("NATIVE_FADE_GEOMETRY "+json.dumps({"name":data["name"],"source":source,"x_range":movement,"samples":len(samples)}))
for file in sorted(out.glob("*")):
    if file.suffix not in [".png", ".json"]:
        continue
    raw=file.read_bytes()
    print(f"NATIVE_FADE_FILE {file.name} sha256={hashlib.sha256(raw).hexdigest()} bytes={len(raw)}")
NX_CAPTURE_ORACLE
cd "$ROOT"
[ "$(git rev-parse HEAD)" = "$SCRIPT_SHA" ] && [ "$(git rev-parse 'HEAD^{tree}')" = "$SCRIPT_TREE" ]
git diff --quiet && git diff --cached --quiet
[ -f "$ROOT/artifacts/pane-overflow-fade.tar.gz" ] || die "measurement archive missing"
archive_sha="$(shasum -a 256 "$ROOT/artifacts/pane-overflow-fade.tar.gz" | awk '{print $1}')"
archive_bytes="$(wc -c < "$ROOT/artifacts/pane-overflow-fade.tar.gz" | tr -d ' ')"
cd "$ROOT"
git diff --quiet && git diff --cached --quiet || die "source changed during measurement"
git status --porcelain --untracked-files=no | grep -q . && die "tracked source changed during measurement" || true
[ "$(git rev-parse HEAD)" = "$SCRIPT_SHA" ] || die "HEAD changed during measurement"
[ "$(git rev-parse 'HEAD^{tree}')" = "$SCRIPT_TREE" ] || die "tree changed during measurement"
printf 'NATIVE_FADE_COMPLETE source=%s tree=%s red=%s red_exit=%s archive=artifacts/pane-overflow-fade.tar.gz archive_sha256=%s archive_bytes=%s\n' "$HEAD_SHA" "$HEAD_TREE" "$RED_SHA" "$RED_EXIT" "$archive_sha" "$archive_bytes"
