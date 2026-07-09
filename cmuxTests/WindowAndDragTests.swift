import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications
// Selective imports: the app target also defines AppIconMode/StoredShortcut/etc.,
// so a blanket `import CmuxSettings` here makes those names ambiguous. Import only
// the settings symbols this file needs.
import struct CmuxSettings.AccountCatalogSection
import struct CmuxSettings.AppCatalogSection
import struct CmuxSettings.FileRouteSettingsStore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Swift Testing shims
//
// This file was migrated from XCTest to Swift Testing wholesale. The
// file-private shims below keep the migrated test bodies byte-compatible with
// their original XCTest assertion call sites (same pattern as
// TerminalControllerSocketSecurityTests.swift).

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 == value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertEqual<T: FloatingPoint>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    accuracy: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(abs(value1 - value2) <= accuracy, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 != value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression(), testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value = try expression()
        #expect(!value, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() == nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() != nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertGreaterThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 > value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 >= value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertLessThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 < value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertIdentical(
    _ expression1: @autoclosure () throws -> AnyObject?,
    _ expression2: @autoclosure () throws -> AnyObject?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 === value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    let value = try expression()
    return try #require(value, testComment(message()), sourceLocation: sourceLocation)
}

private func XCTFail(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
}

final class FakeBonsplitTabItemRegionView: NSView, BonsplitTabItemHitRegionProviding {
    nonisolated(unsafe) var tabFrames: [CGRect] = []

    deinit {}

    nonisolated func containsBonsplitTabItemHit(localPoint: NSPoint) -> Bool {
        tabFrames.contains { $0.contains(localPoint) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
@Suite(.serialized)
final class WindowGlassEffectTests {
    @Test func testRemoveRestoresOriginalContentHierarchy() {
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        let glassEffect = WindowGlassEffect()
        glassEffect.apply(to: window, tintColor: .systemBlue)

        if glassEffect.isAvailable {
            XCTAssertFalse(window.contentView === originalContentView)
            XCTAssertTrue(glassEffect.originalContentView(for: window) === originalContentView)
            XCTAssertTrue(originalContentView.superview === glassEffect.foregroundContainer(for: window))
            XCTAssertNotNil(glassEffect.portalInstallationTarget(for: window))
        } else {
            XCTAssertTrue(window.contentView === originalContentView)
            XCTAssertNil(glassEffect.originalContentView(for: window))
            XCTAssertNil(glassEffect.foregroundContainer(for: window))
            XCTAssertNil(glassEffect.portalInstallationTarget(for: window))
        }
        XCTAssertTrue(Self.windowContainsGlassBackground(window))

        glassEffect.remove(from: window)

        XCTAssertTrue(window.contentView === originalContentView)
        XCTAssertNil(glassEffect.foregroundContainer(for: window))
        XCTAssertNil(glassEffect.originalContentView(for: window))
        XCTAssertFalse(Self.windowContainsGlassBackground(window))
    }

    @Test(.enabled(
        if: NSClassFromString("NSGlassEffectView") != nil,
        "NSGlassEffectView is unavailable on this macOS version"
    ))
    func testNativeGlassTintFollowsWindowKeyNotifications() throws {
        let glassEffect = WindowGlassEffect()
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        glassEffect.apply(to: window, tintColor: .black, style: .clear)

        guard let backgroundView = Self.glassBackgroundView(in: window.contentView),
              let tintOverlay = backgroundView.subviews.last else {
            XCTFail("Expected glass background tint overlay")
            return
        }

        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(tintOverlay.alphaValue, 0, accuracy: 0.001)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
    }

    private static func windowContainsGlassBackground(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let root = contentView.superview ?? contentView
        return glassBackgroundView(in: root) != nil
    }

    private static func glassBackgroundView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier == WindowGlassEffect().backgroundViewIdentifier {
            return view
        }
        return view.subviews.lazy.compactMap(glassBackgroundView(in:)).first
    }
}

@MainActor
@Suite(.serialized)
final class WindowAccessorTests {
    @Test func testSameWindowDedupeAllowsRefreshIDChanges() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
    }

    @Test func testDedupeDisabledAlwaysInvokesForSameWindow() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
    }
}

@MainActor
@Suite(.serialized)
final class MainWindowFocusRedrawTests {
    @Test func testKeyRegainInvalidatesRootContentView() {
        _ = NSApplication.shared

        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.isVertical = true
        splitView.autoresizingMask = [.width, .height]
        splitView.dividerStyle = .thin

        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 420))
        let main = NSView(frame: NSRect(x: 221, y: 0, width: 419, height: 420))
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(main)
        contentView.addSubview(splitView)
        splitView.setPosition(220, ofDividerAt: 0)

        let window = CmuxMainWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.contentView = contentView
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        contentView.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()

        contentView.needsDisplay = false

        appDelegate.handleCmuxWindowResignedKey(
            Notification(name: NSWindow.didResignKeyNotification, object: window)
        )
        appDelegate.handleCmuxWindowBecameKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )

        XCTAssertTrue(
            contentView.needsDisplay,
            "Regaining key focus must invalidate the root content view."
        )
    }
}

@MainActor
@Suite(.serialized)
final class AppDelegateLaunchServicesRegistrationTests {
    @Test func testDefaultTerminalRegistrationKeepsAllAdvertisedTargets() {
        XCTAssertEqual(
            DefaultTerminalRegistration.targetCount,
            DefaultTerminalRegistration.urlSchemes.count + DefaultTerminalRegistration.contentTypeIdentifiers.count
        )
        XCTAssertEqual(
            DefaultTerminalRegistration.contentType(forIdentifier: "com.apple.terminal.shell-script").identifier,
            "com.apple.terminal.shell-script"
        )
    }

    @Test func testScheduleLaunchServicesRegistrationDefersRegisterWork() {
        _ = NSApplication.shared
        let app = AppDelegate()

        var scheduledWork: (@Sendable () -> Void)?
        var registerCallCount = 0

        app.scheduleLaunchServicesBundleRegistrationForTesting(
            bundleURL: URL(fileURLWithPath: "/tmp/../tmp/cmux-launch-services-test.app"),
            scheduler: { work in
                scheduledWork = work
            },
            register: { _ in
                registerCallCount += 1
                return noErr
            }
        )

        XCTAssertEqual(registerCallCount, 0, "Registration should not run inline on the startup call path")
        XCTAssertNotNil(scheduledWork, "Registration work should be handed to the scheduler")

        scheduledWork?()

        XCTAssertEqual(registerCallCount, 1)
    }
}

@Suite(.serialized)
final class TerminalDefaultFileOpenRequestTests {
    @Test func testBuildsQuotedLaunchInputForTerminalCommandFile() throws {
        let contentType = DefaultTerminalRegistration.contentType(forIdentifier: "com.apple.terminal.shell-script")
        let url = URL(fileURLWithPath: "/tmp/cmux default's/Run Me.command")

        let request = try XCTUnwrap(TerminalDefaultFileOpenRequest(fileURL: url, contentType: contentType))

        XCTAssertEqual(request.workingDirectory, "/tmp/cmux default's")
        XCTAssertEqual(request.initialInput, "'/tmp/cmux default'\\''s/Run Me.command'\n")
    }

    @Test func testIgnoresPlainTextFiles() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")

        XCTAssertNil(TerminalDefaultFileOpenRequest(fileURL: url, contentType: .plainText))
    }

    @Test func testBuildsLaunchInputForExtensionlessUnixExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-default-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appendingPathComponent("runme", isDirectory: false)
        try "#!/bin/sh\necho cmux\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let request = try XCTUnwrap(TerminalDefaultFileOpenRequest(fileURL: executable))

        XCTAssertEqual(request.workingDirectory, directory.path)
        XCTAssertEqual(request.initialInput, "'\(executable.path)'\n")
    }

    @Test func testIgnoresDirectoriesWithTerminalScriptExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-default-directory-\(UUID().uuidString).command", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNil(TerminalDefaultFileOpenRequest(fileURL: directory, contentType: .directory))
    }
}


@Suite(.serialized)
final class FocusFlashPatternTests {
    @Test func testFocusFlashPatternMatchesTerminalDoublePulseShape() {
        XCTAssertEqual(FocusFlashPattern.values, [0, 1, 0, 1, 0])
        XCTAssertEqual(FocusFlashPattern.keyTimes, [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(FocusFlashPattern.duration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.curves, [.easeOut, .easeIn, .easeOut, .easeIn])
        XCTAssertEqual(FocusFlashPattern.ringInset, Double(PanelOverlayRingMetrics.inset), accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.ringCornerRadius, Double(PanelOverlayRingMetrics.cornerRadius), accuracy: 0.0001)
    }

    @Test func testFocusFlashPatternSegmentsCoverFullDoublePulseTimeline() {
        let segments = FocusFlashPattern.segments
        XCTAssertEqual(segments.count, 4)

        XCTAssertEqual(segments[0].delay, 0.0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[0].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[0].curve, .easeOut)

        XCTAssertEqual(segments[1].delay, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].curve, .easeIn)

        XCTAssertEqual(segments[2].delay, 0.45, accuracy: 0.0001)
        XCTAssertEqual(segments[2].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[2].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[2].curve, .easeOut)

        XCTAssertEqual(segments[3].delay, 0.675, accuracy: 0.0001)
        XCTAssertEqual(segments[3].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[3].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[3].curve, .easeIn)
    }
}


@available(macOS 26.0, *)
private struct DragConfigurationOperationsSnapshot: Equatable {
    let allowCopy: Bool
    let allowMove: Bool
    let allowDelete: Bool
    let allowAlias: Bool
}

@available(macOS 26.0, *)
private enum DragConfigurationSnapshotError: Error {
    case missingBoolField(primary: String, fallback: String?)
}

@available(macOS 26.0, *)
private func dragConfigurationOperationsSnapshot<T>(from operations: T) throws -> DragConfigurationOperationsSnapshot {
    let mirror = Mirror(reflecting: operations)

    func readBool(_ primary: String, fallback: String? = nil) throws -> Bool {
        if let value = mirror.descendant(primary) as? Bool {
            return value
        }
        if let fallback, let value = mirror.descendant(fallback) as? Bool {
            return value
        }
        throw DragConfigurationSnapshotError.missingBoolField(primary: primary, fallback: fallback)
    }

    return try DragConfigurationOperationsSnapshot(
        allowCopy: readBool("allowCopy", fallback: "_allowCopy"),
        allowMove: readBool("allowMove", fallback: "_allowMove"),
        allowDelete: readBool("allowDelete", fallback: "_allowDelete"),
        allowAlias: readBool("allowAlias", fallback: "_allowAlias")
    )
}

#if compiler(>=6.2)
@MainActor
@Suite(.serialized)
final class InternalTabDragConfigurationTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ),
        "requires macOS 26 drag configuration APIs"
    ))
    func testDisablesExternalOperationsForInternalTabDrags() throws {
        guard #available(macOS 26.0, *) else {
            // Unreachable: the enabled(if:) trait skips below macOS 26; this
            // guard only satisfies the compiler's availability checking.
            return
        }

        let configuration = InternalTabDragConfigurationProvider.value
        let withinApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsWithinApp)
        let outsideApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsOutsideApp)

        XCTAssertEqual(
            withinApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: true,
                allowDelete: false,
                allowAlias: false
            )
        )

        XCTAssertEqual(
            outsideApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: false,
                allowDelete: false,
                allowAlias: false
            )
        )
    }
}


@MainActor
@Suite(.serialized)
final class InternalTabDragBundleDeclarationTests {
    private func exportedTypeIdentifiers(bundle: Bundle) -> Set<String> {
        let declarations = (bundle.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]) ?? []
        return Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
    }

    @Test func testAppBundleExportsInternalDragTypes() {
        let exported = exportedTypeIdentifiers(bundle: Bundle(for: AppDelegate.self))

        XCTAssertTrue(
            exported.contains("com.splittabbar.tabtransfer"),
            "Expected app bundle to export bonsplit tab-transfer type, got \(exported)"
        )
        XCTAssertTrue(
            exported.contains("com.cmux.sidebar-tab-reorder"),
            "Expected app bundle to export sidebar tab-reorder type, got \(exported)"
        )
    }
}
#endif


@MainActor
@Suite(.serialized)
final class WindowDragHandleHitTests {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class HostContainerView: NSView {}
    private final class BlockingTopHitContainerView: NSView {
        var hitCount = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            hitCount += 1
            return bounds.contains(point) ? self : nil
        }
    }
    private final class PassThroughProbeView: NSView {
        var onHitTest: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            onHitTest?()
            return nil
        }
    }
    private final class PassiveHostContainerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            return super.hitTest(point) ?? self
        }
    }

    private final class SidebarActionRegionView: NSView, MinimalModeSidebarControlActionHitRegionProviding {
        nonisolated(unsafe) var config = TitlebarControlsStyle.classic.config

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        nonisolated func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
            minimalModeSidebarControlActionSlot(localPoint: localPoint) != nil
        }

        nonisolated func minimalModeSidebarControlActionSlot(localPoint: NSPoint) -> MinimalModeSidebarControlActionSlot? {
            let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
            for (index, range) in ranges.enumerated() where range.contains(localPoint.x) {
                return MinimalModeSidebarControlActionSlot(rawValue: index)
            }
            return nil
        }
    }

    private final class MutatingSiblingView: NSView {
        weak var container: NSView?
        private var didMutate = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            guard !didMutate, let container else { return nil }
            didMutate = true
            let transient = NSView(frame: .zero)
            container.addSubview(transient)
            transient.removeFromSuperview()
            return nil
        }
    }

    private final class ReentrantDragHandleView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let shouldCapture = windowDragHandleShouldCaptureHit(point, in: self, eventType: .leftMouseDown, eventWindow: self.window)
            return shouldCapture ? self : nil
        }
    }

    private final class RecordingTitlebarActionWindow: NSWindow {
        var zoomCallCount = 0
        var miniaturizeCallCount = 0

        override func zoom(_ sender: Any?) {
            zoomCallCount += 1
        }

        override func miniaturize(_ sender: Any?) {
            miniaturizeCallCount += 1
        }
    }

    /// A sibling view whose hitTest re-enters windowDragHandleShouldCaptureHit,
    /// simulating the crash path where sibling.hitTest triggers a SwiftUI layout
    /// pass that calls back into the drag handle's hit resolution.
    private final class ReentrantSiblingView: NSView {
        weak var dragHandle: NSView?
        var reenteredResult: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let dragHandle else { return nil }
            // Simulate the re-entry: during sibling hit test, SwiftUI layout
            // calls windowDragHandleShouldCaptureHit on the drag handle again.
            reenteredResult = windowDragHandleShouldCaptureHit(
                point, in: dragHandle, eventType: .leftMouseDown, eventWindow: dragHandle.window
            )
            return nil
        }
    }

    private static func firstSubview(
        in view: NSView,
        matching predicate: (NSView) -> Bool
    ) -> NSView? {
        if predicate(view) {
            return view
        }

        for subview in view.subviews {
            if let match = firstSubview(in: subview, matching: predicate) {
                return match
            }
        }

        return nil
    }

    private static func firstCapturableTitlebarPoint(
        in dragHandle: NSView,
        window: NSWindow
    ) -> NSPoint? {
        let bounds = dragHandle.bounds.insetBy(dx: 4, dy: 4)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let yCandidates = [
            bounds.midY,
            bounds.minY + bounds.height * 0.25,
            bounds.minY + bounds.height * 0.75
        ]

        for y in yCandidates {
            var x = bounds.maxX
            while x >= bounds.minX {
                let point = NSPoint(x: x, y: y)
                if windowDragHandleShouldCaptureHit(
                    point,
                    in: dragHandle,
                    eventType: .leftMouseDown,
                    eventWindow: window
                ) {
                    return point
                }
                x -= 4
            }
        }

        return nil
    }

    @Test func testDragHandleCapturesHitWhenNoSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Empty titlebar space should drag the window"
        )
    }

    @Test func testDragHandleYieldsWhenSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let folderIconHost = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        container.addSubview(folderIconHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive titlebar controls should receive the mouse event"
        )
        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    @Test func testTitlebarControlGapsAreOutsideButtonHitColumns() {
        let config = TitlebarControlsStyle.classic.config
        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
        XCTAssertEqual(ranges.count, MinimalModeSidebarControlActionSlot.allCases.count)
        XCTAssertEqual(
            MinimalModeSidebarControlActionSlot.allCases.map(\.accessibilityIdentifier),
            [
                "titlebarControl.toggleSidebar",
                "titlebarControl.showNotifications",
                "titlebarControl.newTab",
                "titlebarControl.cloudVM",
                "titlebarControl.focusHistoryBack",
                "titlebarControl.focusHistoryForward",
            ],
            "The hidden minimal-mode click lanes must match the visible titlebar control order."
        )
        XCTAssertEqual(
            ranges[0].lowerBound,
            TitlebarControlsLayoutMetrics.hintLeadingPadding + config.groupPadding.leading,
            accuracy: 0.001,
            "Hidden titlebar hit regions should share the visible titlebar control leading position."
        )

        XCTAssertTrue(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(
                NSPoint(x: ranges[0].lowerBound + 1, y: 14),
                config: config
            ),
            "Icon button columns should stay interactive"
        )
        XCTAssertEqual(
            ranges[MinimalModeSidebarControlActionSlot.cloudVM.rawValue].upperBound
                - ranges[MinimalModeSidebarControlActionSlot.cloudVM.rawValue].lowerBound,
            TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownWidth(config: config),
            accuracy: 0.001,
            "The hidden Cloud menu lane should match the visible split-button dropdown width."
        )
        XCTAssertLessThan(
            TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownIconSize(config: config),
            config.iconSize - 2,
            "The Cloud dropdown glyph should stay visibly smaller than the primary titlebar icons."
        )
        XCTAssertTrue(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(
                NSPoint(
                    x: (
                        ranges[MinimalModeSidebarControlActionSlot.cloudVM.rawValue].lowerBound
                            + ranges[MinimalModeSidebarControlActionSlot.cloudVM.rawValue].upperBound
                    ) / 2,
                    y: 14
                ),
                config: config
            ),
            "The padded Cloud dropdown lane should receive left clicks."
        )
        XCTAssertTrue(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(
                NSPoint(x: ranges[MinimalModeSidebarControlActionSlot.cloudVM.rawValue].lowerBound + 1, y: 14),
                config: config
            ),
            "The leading padding inside the Cloud dropdown lane should receive left clicks."
        )
        XCTAssertTrue(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(
                NSPoint(x: ranges[MinimalModeSidebarControlActionSlot.cloudVM.rawValue].upperBound - 1, y: 14),
                config: config
            ),
            "The trailing padding inside the Cloud dropdown lane should receive left clicks."
        )

        let firstGapX = (ranges[0].upperBound + ranges[1].lowerBound) / 2
        let secondGapX = (ranges[1].upperBound + ranges[2].lowerBound) / 2

        XCTAssertFalse(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(NSPoint(x: firstGapX, y: 14), config: config),
            "The gap between the sidebar and notification icons should remain available for window dragging"
        )
        XCTAssertFalse(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(NSPoint(x: secondGapX, y: 14), config: config),
            "The gap between the notification and new-workspace icons should remain available for window dragging"
        )

        XCTAssertGreaterThanOrEqual(
            MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            ranges.last?.upperBound ?? 0,
            "The minimal-mode host must be wide enough to preserve the back/forward button lanes."
        )
    }

    @Test func testDragHandleYieldsToRegisteredMinimalModeSidebarButtonColumns() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let dragHandle = NSView(frame: contentView.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        contentView.addSubview(dragHandle)

        let controlRegion = SidebarActionRegionView(
            frame: NSRect(
                x: 72,
                y: 88,
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )
        )
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: controlRegion.config)
        let backButtonPoint = NSPoint(
            x: controlRegion.frame.minX + ranges[MinimalModeSidebarControlActionSlot.focusHistoryBack.rawValue].lowerBound + 1,
            y: controlRegion.frame.midY
        )
        XCTAssertTrue(isMinimalModeTitlebarControlHit(window: window, locationInWindow: backButtonPoint))
        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                dragHandle.convert(backButtonPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Registered minimal-mode titlebar buttons should not fall through to the window drag handle."
        )

        let emptyTitlebarPoint = NSPoint(x: contentView.bounds.maxX - 20, y: controlRegion.frame.midY)
        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                dragHandle.convert(emptyTitlebarPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty titlebar space should still be draggable."
        )
    }

    @Test func testMinimalModeSidebarFallbackHitUsesHardcodedLeadingInset() {
        let suiteName = "WindowDragHandleHitTests.leadingInset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let firstButtonX = TitlebarControlsHitRegions.buttonXRanges(config: TitlebarControlsStyle.classic.config)[0].lowerBound + 1
        let titlebarY = contentView.bounds.maxY - 4
        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(
                window: window,
                locationInWindow: NSPoint(
                    x: CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset) + firstButtonX,
                    y: titlebarY
                ),
                defaults: defaults
            ),
            .toggleSidebar
        )
    }

    @Test func testMinimalModeSidebarTitlebarControlsAlignWithTrafficLightCenter() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        // WindowDecorationsController.apply reads the production presentation-mode setting
        // from UserDefaults.standard, so this test saves and restores the shared key narrowly.
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            if let savedMode {
                defaults.set(savedMode, forKey: WorkspacePresentationModeSettings.modeKey)
            } else {
                defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.orderOut(nil) }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let closeButtonSuperview = closeButton.superview else {
            XCTFail("Expected close traffic-light button")
            return
        }

        let controller = WindowDecorationsController()
        controller.apply(to: window)

        guard let target = contentView.subviews.compactMap({ $0 as? MinimalModeSidebarControlActionView }).first else {
            XCTFail("Expected minimal sidebar titlebar click target")
            return
        }

        let trafficLightFrame = closeButtonSuperview.convert(closeButton.frame, to: contentView)
        XCTAssertEqual(
            target.frame.midY,
            trafficLightFrame.midY,
            accuracy: 0.25,
            "Minimal-mode sidebar controls should share the traffic-light center Y"
        )
    }

    @Test func testTitlebarChromeSettingsUseDefaultsAndStoredOverrides() {
        let suiteName = "WindowDragHandleHitTests.titlebarChromeSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(
            snapshot.leftControlsLeadingInset,
            MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            snapshot.leftControlsTopInset,
            MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset),
            accuracy: 0.001
        )
        XCTAssertEqual(
            MinimalModeSidebarTitlebarControlsMetrics.topInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset),
            accuracy: 0.001
        )

        defaults.set(44.5, forKey: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
        defaults.set(6.5, forKey: MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
        defaults.set(12.0, forKey: "titlebarDebug.trafficLightsXOffset")
        defaults.set(-3.0, forKey: "titlebarDebug.trafficLightsYOffset")
        defaults.set(88.0, forKey: MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey)
        defaults.set(92.0, forKey: MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey)

        let storedSnapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(storedSnapshot.leftControlsLeadingInset, 44.5, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.leftControlsTopInset, 6.5, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.trafficLightTabBarLeadingInset, 88.0, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.trafficLightTitlebarLeadingInset, 92.0, accuracy: 0.001)

        defaults.set(999.0, forKey: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
        XCTAssertEqual(
            MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.horizontalInsetRange.upperBound),
            accuracy: 0.001
        )
    }

    @Test func testTitlebarChromeSettingsIgnoreLegacyNativeTrafficLightOffsets() {
        let suiteName = "WindowDragHandleHitTests.titlebarChromeLegacyTrafficLights.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(44.0, forKey: "titlebarDebug.trafficLightsXOffset")
        defaults.set(-12.0, forKey: "titlebarDebug.trafficLightsYOffset")

        let snapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(
            snapshot,
            MinimalModeTitlebarDebugSnapshot(
                leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
                leftControlsTopInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
                trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
                trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
            )
        )
    }

    @Test func testDragHandleIgnoresHiddenSiblingWhenResolvingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let hidden = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        hidden.isHidden = true
        container.addSubview(hidden)

        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown))
    }

    @Test func testDragHandleDoesNotCaptureOutsideBounds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertFalse(windowDragHandleShouldCaptureHit(NSPoint(x: 240, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    @Test func testDragHandleSkipsCaptureForPassivePointerEvents() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let point = NSPoint(x: 180, y: 18)
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .mouseMoved))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .cursorUpdate))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: nil))
        XCTAssertTrue(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown))
    }

    @Test func testDragHandleNeverCapturesRegisteredBonsplitPaneTab() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)

        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 82, width: 220, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        container.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        let tabWindowPoint = tabRegion.convert(NSPoint(x: 48, y: 15), to: nil)
        let tabDragHandlePoint = dragHandle.convert(tabWindowPoint, from: nil)
        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                tabDragHandlePoint,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "A visible pane tab must own its mouse-down; the titlebar drag handle must not turn it into a window drag"
        )

        let emptyWindowPoint = tabRegion.convert(NSPoint(x: 180, y: 15), to: nil)
        let emptyDragHandlePoint = dragHandle.convert(emptyWindowPoint, from: nil)
        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                emptyDragHandlePoint,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty tab-strip chrome should remain available for app-window dragging"
        )
    }

    @Test func testTabBarEmptyChromeOverlayNeverCapturesRegisteredBonsplitPaneTabWhenFrameCacheIsEmpty() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let dragZone = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 72, width: 320, height: 30))
        dragZone.hitRegion = .trailingEmptyChrome(tabFrames: [], reservedTrailingWidth: 48)
        dragZone.hitTestEventTypeOverride = .leftMouseDown
        contentView.addSubview(dragZone)

        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 10, y: 72, width: 90, height: 30))
        tabRegion.tabFrames = [tabRegion.bounds]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        XCTAssertNil(
            dragZone.hitTest(NSPoint(x: 40, y: 15)),
            "The empty-chrome overlay must not turn a pane-tab mouse-down into an app-window drag while tab frames are still populating"
        )
        XCTAssertIdentical(
            dragZone.hitTest(NSPoint(x: 140, y: 15)),
            dragZone,
            "Empty tab-strip chrome after the registered tab should still be available for app-window dragging"
        )
    }

    @Test func testDragHandleSkipsForeignLeftMouseDownDuringLaunch() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = NSView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { foreignWindow.orderOut(nil) }

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: nil
            ),
            "Launch activation events without a matching window should not trigger drag-handle hierarchy walk"
        )

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: foreignWindow
            ),
            "Left mouse-down events for a different window should be treated as passive"
        )

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Left mouse-down events for this window should still capture empty titlebar space"
        )
    }

    @Test func testPassiveHostingTopHitClassification() {
        XCTAssertTrue(windowDragHandleShouldTreatTopHitAsPassiveHost(HostContainerView(frame: .zero)))
        XCTAssertFalse(windowDragHandleShouldTreatTopHitAsPassiveHost(NSButton(frame: .zero)))
    }

    @Test func testMinimalModeTitlebarControlRegionRegistryMatchesVisibleRegisteredView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = NSView(frame: NSRect(x: 72, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertTrue(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)))
        XCTAssertFalse(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 20, y: 100)))

        controlRegion.isHidden = true
        XCTAssertFalse(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)))
    }

    @Test func testMinimalModeTitlebarControlRegionCanLimitHitsInsideRegisteredView() {
        final class ButtonOnlyRegion: NSView, MinimalModeTitlebarControlHitRegionProviding {
            nonisolated func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
                localPoint.x >= 24 && localPoint.x <= 48
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = ButtonOnlyRegion(frame: NSRect(x: 72, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertTrue(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)),
            "Expected points inside the provider's button range to suppress titlebar double-click handling."
        )
        XCTAssertFalse(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 136, y: 100)),
            "Expected gaps inside the registered view to keep behaving like titlebar chrome."
        )
    }

    @Test func testMinimalModeSidebarActionSlotUsesRegisteredHostFrame() {
        let suiteName = "WindowDragHandleHitTests.sidebarHostFrame.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = SidebarActionRegionView(frame: NSRect(x: 88, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(
                window: window,
                locationInWindow: NSPoint(x: controlRegion.frame.minX + 50, y: controlRegion.frame.minY + 14),
                defaults: defaults
            ),
            .showNotifications,
            "Sidebar control actions should use the actual registered host frame instead of a fixed window x origin."
        )
    }

    @Test func testMinimalModeSidebarActionSlotUsesRegisteredHostFrameBelowFallbackBand() {
        let suiteName = "WindowDragHandleHitTests.sidebarHostFrameBand.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = SidebarActionRegionView(frame: NSRect(x: 88, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        let point = NSPoint(x: controlRegion.frame.minX + 14, y: controlRegion.frame.minY + 1)
        XCTAssertFalse(
            isPointInMinimalModeTitlebarBand(
                isEnabled: true,
                point: point,
                bounds: contentView.bounds,
                topStripHeight: MinimalModeChromeMetrics.titlebarHeight
            ),
            "The regression point should sit inside the visual control host but outside the hard-coded fallback band."
        )
        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(window: window, locationInWindow: point, defaults: defaults),
            .toggleSidebar
        )
        XCTAssertTrue(
            isMinimalModeSidebarChromeHoverCandidate(window: window, locationInWindow: point, defaults: defaults),
            "Hover reveal should follow the real control host frame."
        )
    }

    @Test func testSuppressedTitlebarDoubleClickConsumesWithoutWindowAction() {
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .suppress),
            .suppressed
        )
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .standardAction),
            .ignored
        )
        XCTAssertTrue(TitlebarDoubleClickHandlingResult.suppressed.consumesEvent)
        XCTAssertFalse(TitlebarDoubleClickHandlingResult.ignored.consumesEvent)
    }

    @Test func testMinimalModeDoubleClickHandlerOnlyHandlesTopStripDoubleClicks() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 240),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: false,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 1,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
    }

    @Test func testMinimalModeWindowDoubleClickRequiresMainTopStrip() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: false,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: true,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: false,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 240),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
    }

    @Test func testMinimalModeTitlebarConsecutiveClicksCanFormDoubleClick() {
        let previous = MinimalModeTitlebarClickRecord(
            windowNumber: 42,
            timestamp: 10,
            locationInWindow: NSPoint(x: 200, y: 292)
        )

        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.65,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.62,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5,
                doubleClickIntervalTolerance: 0.15
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 2,
                timestamp: 20,
                locationInWindow: NSPoint(x: 20, y: 20),
                windowNumber: 99,
                previous: nil,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.8,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 240, y: 292),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 43,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
    }

    @Test func testDragHandleIgnoresPassiveHostSiblingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        container.addSubview(passiveHost)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Passive host wrappers should not block titlebar drag capture"
        )
    }

    @Test func testDragHandleRespectsInteractiveChildInsidePassiveHost() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        let folderControl = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        passiveHost.addSubview(folderControl)
        container.addSubview(passiveHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive controls inside passive host wrappers should still receive hits"
        )
    }

    @Test func testTopHitResolutionStateIsScopedPerWindow() {
        let point = NSPoint(x: 100, y: 18)

        let outerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { outerWindow.orderOut(nil) }
        guard let outerContentView = outerWindow.contentView else {
            XCTFail("Expected outer content view")
            return
        }
        let outerContainer = NSView(frame: outerContentView.bounds)
        outerContainer.autoresizingMask = [.width, .height]
        outerContentView.addSubview(outerContainer)
        let outerDragHandle = NSView(frame: outerContainer.bounds)
        outerDragHandle.autoresizingMask = [.width, .height]
        outerContainer.addSubview(outerDragHandle)

        let nestedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { nestedWindow.orderOut(nil) }
        guard let nestedContentView = nestedWindow.contentView else {
            XCTFail("Expected nested content view")
            return
        }
        let nestedContainer = NSView(frame: nestedContentView.bounds)
        nestedContainer.autoresizingMask = [.width, .height]
        nestedContentView.addSubview(nestedContainer)
        let nestedDragHandle = NSView(frame: nestedContainer.bounds)
        nestedDragHandle.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedDragHandle)
        let nestedBlockingOverlay = BlockingTopHitContainerView(frame: nestedContainer.bounds)
        nestedBlockingOverlay.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedBlockingOverlay)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow),
            "Nested window drag handle should be blocked by top-hit titlebar container"
        )
        XCTAssertEqual(nestedBlockingOverlay.hitCount, 1)

        var nestedCaptureResult: Bool?
        let probe = PassThroughProbeView(frame: outerContainer.bounds)
        probe.autoresizingMask = [.width, .height]
        probe.onHitTest = {
            nestedCaptureResult = windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow)
        }
        outerContainer.addSubview(probe)

        _ = windowDragHandleShouldCaptureHit(point, in: outerDragHandle, eventType: .leftMouseDown, eventWindow: outerWindow)

        XCTAssertEqual(
            nestedCaptureResult,
            false,
            "Top-hit recursion in one window must not disable top-hit resolution in another window"
        )
        XCTAssertEqual(
            nestedBlockingOverlay.hitCount,
            2,
            "Nested window should resolve its own blocking sibling while another window is resolving hits"
        )
    }

    @Test func testDragHandleRemainsStableWhenSiblingMutatesSubviewsDuringHitTest() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let mutatingSibling = MutatingSiblingView(frame: container.bounds)
        mutatingSibling.container = container
        container.addSubview(mutatingSibling)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Subview mutations during hit testing should not crash or break drag-handle capture"
        )
    }

    @Test func testDragHandleSiblingHitTestReentrancyDoesNotCrash() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let reentrantSibling = ReentrantSiblingView(frame: container.bounds)
        reentrantSibling.dragHandle = dragHandle
        container.addSubview(reentrantSibling)

        // The outer call enters the sibling walk, which calls
        // reentrantSibling.hitTest(), which re-enters
        // windowDragHandleShouldCaptureHit. Without the re-entrancy guard
        // this would trigger a Swift exclusive-access violation (SIGABRT).
        let outerResult = windowDragHandleShouldCaptureHit(
            NSPoint(x: 110, y: 18), in: dragHandle, eventType: .leftMouseDown
        )
        XCTAssertTrue(outerResult, "Outer call should still capture when sibling returns nil")
        XCTAssertEqual(
            reentrantSibling.reenteredResult, false,
            "Re-entrant call should bail out (return false) instead of crashing"
        )
    }

    @Test func testDragHandleTopHitResolutionSurvivesSameWindowReentrancy() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = ReentrantDragHandleView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown, eventWindow: window),
            "Reentrant same-window top-hit resolution should not trigger exclusivity crashes"
        )
    }

    @Test func testRightSidebarModeBarEmptySpaceDoubleClickPerformsTitlebarAction() {
        _ = NSApplication.shared

        let previousGlobalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        var testGlobalDefaults = previousGlobalDefaults ?? [:]
        testGlobalDefaults["AppleActionOnDoubleClick"] = "Fill"
        testGlobalDefaults["AppleMiniaturizeOnDoubleClick"] = false
        UserDefaults.standard.setPersistentDomain(testGlobalDefaults, forName: UserDefaults.globalDomain)
        defer {
            if let previousGlobalDefaults {
                UserDefaults.standard.setPersistentDomain(previousGlobalDefaults, forName: UserDefaults.globalDomain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: UserDefaults.globalDomain)
            }
        }

        let window = RecordingTitlebarActionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let rootView = RightSidebarPanelView(
            tabManager: TabManager(),
            fileExplorerStore: FileExplorerStore(),
            fileExplorerState: FileExplorerState(),
            sessionIndexStore: SessionIndexStore(),
            notesTreeStore: NotesTreeStore(),
            titlebarHeight: 36, windowAppearance: .rightSidebarPanelViewTestDefault,
            workspaceId: nil,
            onResumeSession: nil,
            onOpenFilePreview: { _ in },
            onOpenNote: { _, _ in },
            onResumeNoteSession: { _ in },
            onFocusNoteTerminal: { _ in },
            onResolveTerminalNoteTarget: { _ in nil },
            onOpenAsPane: { _ in },
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        guard let dragHandle = Self.firstSubview(
            in: hostingView,
            matching: { $0.identifier == WindowDragHandleView.viewIdentifier }
        ) else {
            XCTFail("Expected right-sidebar mode bar to install a titlebar drag handle")
            return
        }

        guard let emptyModeBarLocalPoint = Self.firstCapturableTitlebarPoint(
            in: dragHandle,
            window: window
        ) else {
            XCTFail("Expected right-sidebar mode bar to expose at least one empty titlebar point")
            return
        }

        let emptyModeBarPoint = dragHandle.convert(emptyModeBarLocalPoint, to: nil as NSView?)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: emptyModeBarPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        ) else {
            XCTFail("Expected to create right-sidebar mode-bar double-click event")
            return
        }

        NSApp.sendEvent(event)

        XCTAssertEqual(window.zoomCallCount, 1)
        XCTAssertEqual(window.miniaturizeCallCount, 0)
    }
}

#if DEBUG


@MainActor
@Suite(.serialized)
final class DraggableFolderHitTests {
    @Test func testFolderHitTestReturnsContainerWhenInsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        guard let hit = folderView.hitTest(NSPoint(x: 8, y: 8)) else {
            XCTFail("Expected folder icon to capture inside hit")
            return
        }
        XCTAssertTrue(hit === folderView)
    }

    @Test func testFolderHitTestReturnsNilOutsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        XCTAssertNil(folderView.hitTest(NSPoint(x: 20, y: 8)))
    }

    @Test func testFolderIconDisablesWindowMoveBehavior() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertFalse(folderView.mouseDownCanMoveWindow)
    }
}


@MainActor
@Suite struct MainWindowHostingViewTests {
    @Test func testReportsPolicyMinimumInsteadOfChildMinimum() {
        _ = NSApplication.shared

        let root = HStack(spacing: 0) {
            Color.clear
                .frame(width: 900, height: 240)
        }
            .frame(
                minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
                minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
            )
        let hostingView = MainWindowHostingView(rootView: root)
        let expectedMinimumWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)

        for width in [520, 1_200] as [CGFloat] {
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 500)
            hostingView.layoutSubtreeIfNeeded()

            #expect(
                abs(hostingView.fittingSize.width - expectedMinimumWidth) <= 0.001,
                "Main window AppKit fitting width must equal minimumWindowWidth at \(width)pt."
            )
            #expect(
                abs(hostingView.intrinsicContentSize.width - expectedMinimumWidth) <= 0.001,
                "Main window AppKit intrinsic width must equal minimumWindowWidth at \(width)pt."
            )
        }
    }

    @Test func testStandardFrameKeepsAppKitDefaultFrameWhenLargerThanPolicyMinimum() {
        let defaultFrame = NSRect(x: 20, y: 40, width: 1_000, height: 700)

        #expect(CmuxMainWindow.standardFrame(forDefaultFrame: defaultFrame) == defaultFrame)
    }

    @Test func testStandardFrameDoesNotShrinkBelowPolicyMinimum() {
        let tinyDefaultFrame = NSRect(x: 20, y: 40, width: 100, height: 80)
        let standardFrame = CmuxMainWindow.standardFrame(forDefaultFrame: tinyDefaultFrame)

        #expect(standardFrame.origin == tinyDefaultFrame.origin)
        #expect(standardFrame.width == CGFloat(SessionPersistencePolicy.minimumWindowWidth))
        #expect(standardFrame.height == CGFloat(SessionPersistencePolicy.minimumWindowHeight))
    }
}

@MainActor
@Suite(.serialized)
final class MainWindowDragBehaviorTests {
    @Test func testMainWindowHostingViewCannotMoveWindowViaMouseDown() {
        let view = MainWindowHostingView(rootView: Color.clear)
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "Main content must never become an implicit AppKit window-drag region; explicit titlebar chrome owns app-window dragging"
        )
    }

    @Test func testMainWindowDragBehaviorRequiresExplicitDragZones() {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.isMovable = true
        window.isMovableByWindowBackground = true

        configureCmuxMainWindowDragBehavior(window)

        XCTAssertFalse(
            window.isMovable,
            "Main windows must not use native AppKit titlebar dragging because pane tabs live in the titlebar band"
        )
        XCTAssertFalse(window.isMovableByWindowBackground)

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(
            window.isMovable,
            "Explicit chrome drag zones may temporarily enable movement, but the main window must return to pane-tab-safe immovable state"
        )
    }
}


@Suite("Custom titlebar leading padding")
struct CustomTitlebarLeadingPaddingTests {
    @Test func hiddenSidebarUsesMinimumSidebarTitleInset() {
        #expect(
            ContentView.customTitlebarLeadingPadding(
                isFullScreen: false,
                isSidebarVisible: false,
                sidebarWidth: 216,
                minimumSidebarWidth: 216,
                titlebarLeadingInset: 82
            ) == 228
        )
    }

    @Test func minimumWidthVisibleSidebarMatchesHiddenSidebarTitleInset() {
        let hidden = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: false,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )
        let visible = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )

        #expect(visible == hidden)
    }

    @Test func widerSidebarPushesTitlebarContentRight() {
        let hidden = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: false,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )
        let visible = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 320,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )

        #expect(visible > hidden)
        #expect(visible == 332)
    }

    @Test func fullscreenHiddenSidebarKeepsCompactInset() {
        #expect(
            ContentView.customTitlebarLeadingPadding(
                isFullScreen: true,
                isSidebarVisible: false,
                sidebarWidth: 216,
                minimumSidebarWidth: 216,
                titlebarLeadingInset: 82
            ) == 8
        )
    }

    // Regression: at the default (== minimum) sidebar width, toggling the sidebar
    // must not move the folder/title. The title tracks the actual width only when
    // the sidebar is wider than the minimum, so the default width must equal the
    // minimum for the visible and hidden insets to match.
    @Test func togglingSidebarAtDefaultWidthDoesNotMoveTitle() {
        let width = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)
        let minimum = CGFloat(SessionPersistencePolicy.minimumSidebarWidth)
        let visible = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: width,
            minimumSidebarWidth: minimum,
            titlebarLeadingInset: 82
        )
        let hidden = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: false,
            sidebarWidth: width,
            minimumSidebarWidth: minimum,
            titlebarLeadingInset: 82
        )
        #expect(visible == hidden)
    }
}


@Suite("Fullscreen titlebar controls placement")
struct FullscreenControlsPlacementTests {
    @Test func notShownOutsideFullscreen() {
        #expect(
            ContentView.fullscreenControlsPlacement(
                isFullScreen: false,
                isSidebarVisible: true
            ) == nil
        )
        #expect(
            ContentView.fullscreenControlsPlacement(
                isFullScreen: false,
                isSidebarVisible: false
            ) == nil
        )
    }

    // Regression: in fullscreen, toggling the sidebar used to shift the accessory
    // bar a few pixels left and up because the controls were mounted in two
    // anchors with different padding. Placement must be identical regardless of
    // sidebar visibility.
    @Test func placementIsIndependentOfSidebarVisibility() {
        let visible = ContentView.fullscreenControlsPlacement(
            isFullScreen: true,
            isSidebarVisible: true
        )
        let hidden = ContentView.fullscreenControlsPlacement(
            isFullScreen: true,
            isSidebarVisible: false
        )

        #expect(visible != nil)
        #expect(visible == hidden)
    }
}


@MainActor
@Suite(.serialized)
final class FolderWindowMoveSuppressionTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    @Test func testSuppressionTracksMovableWindowWithoutChangingMovability() {
        let window = makeWindow()
        window.isMovable = true

        let depth = beginWindowDragSuppression(window: window)

        XCTAssertEqual(depth, 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    @Test func testSuppressionTracksImmovableWindowWithoutChangingMovability() {
        let window = makeWindow()
        window.isMovable = false

        let depth = beginWindowDragSuppression(window: window)

        XCTAssertEqual(depth, 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertFalse(window.isMovable)
    }

    @Test func testEndingSuppressionDoesNotRestoreStaleMovability() {
        let window = makeWindow()
        window.isMovable = false

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertFalse(window.isMovable)

        window.isMovable = true

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    @Test func testClearWindowDragSuppressionRemovesAllDepth() {
        let window = makeWindow()
        window.isMovable = false

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)

        XCTAssertEqual(clearWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(window.isMovable)
    }

    @Test func testClearWindowDragSuppressionFinishesActiveMoveSequence() {
        let window = makeWindow()
        window.isMovable = true

        XCTAssertEqual(
            beginWindowMoveSuppressionSequence(window: window, reason: .bonsplitPaneTabDrag),
            .bonsplitPaneTabDrag
        )
        XCTAssertFalse(window.isMovable)
        XCTAssertEqual(activeWindowMoveSuppressionSequenceReason(window: window), .bonsplitPaneTabDrag)

        XCTAssertEqual(clearWindowDragSuppression(window: window), 0)

        XCTAssertNil(activeWindowMoveSuppressionSequenceReason(window: window))
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    @Test func testWindowDragSuppressionDepthLifecycle() {
        let window = makeWindow()
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    @Test func testWindowDragSuppressionIsReferenceCounted() {
        let window = makeWindow()
        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    @Test func testTemporaryWindowMovableEnableRestoresImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    @Test func testTemporaryWindowMovableEnablePreservesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, true)
        XCTAssertTrue(window.isMovable)
    }
}


@MainActor
@Suite(.serialized)
final class FilePreviewDragPasteboardWriterTests {
    init() {
        FilePreviewDragRegistry.shared.discardAll()
        NSPasteboard(name: .drag).clearContents()
    }

    deinit {
        NSPasteboard(name: .drag).clearContents()
        FilePreviewDragRegistry.shared.discardAll()
    }

    @Test func testRegistrationIsPreparedWhenDragTypesAreRequested() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/example.txt").standardizedFileURL
        let writer = FilePreviewDragPasteboardWriter(
            filePath: fileURL.path,
            displayTitle: "example.txt"
        )
        let dragPasteboard = NSPasteboard(name: .drag)

        XCTAssertNil(FilePreviewDragPasteboardWriter.dragID(from: dragPasteboard))
        let writableTypes = writer.writableTypes(for: dragPasteboard)
        XCTAssertTrue(writableTypes.contains(.fileURL))
        let preparedDragID = try XCTUnwrap(FilePreviewDragPasteboardWriter.dragID(from: dragPasteboard))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: preparedDragID))
        XCTAssertEqual(
            writer.pasteboardPropertyList(forType: .fileURL) as? String,
            fileURL.absoluteString
        )

        let filePreviewData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: DragOverlayRoutingPolicy.filePreviewTransferType) as? Data
        )
        let dragID = try XCTUnwrap(FilePreviewDragPasteboardWriter.dragID(from: filePreviewData))
        XCTAssertEqual(dragID, preparedDragID)
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: dragID))

        let bonsplitData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType) as? Data
        )
        XCTAssertEqual(FilePreviewDragPasteboardWriter.dragID(from: bonsplitData), dragID)
        XCTAssertEqual(dragPasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.data(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.string(forType: .fileURL), fileURL.absoluteString)

        FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: dragPasteboard)

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: dragID))
    }

    @Test func testRegistrySweepsExpiredDragEntries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let oldID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/old.txt", displayTitle: "old.txt"),
            now: start
        )
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(30)))

        let newID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/new.txt", displayTitle: "new.txt"),
            now: start.addingTimeInterval(61)
        )

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(61)))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: newID, now: start.addingTimeInterval(61)))
    }
}


@MainActor
@Suite(.serialized)
final class FilePreviewPanelTextSavingTests {
    @Test func testNativePreviewSessionsDetachAndManageViewsAcrossRecreation() throws {
        let url = try temporaryTextFile(contents: "preview", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        let sessions = panel.nativeViewSessions

        let pdfView = sessions.pdf.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let imageView = sessions.image.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let mediaView = sessions.media.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let quickLookView = sessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )

        let host = NSView()
        host.addSubview(pdfView)
        host.addSubview(imageView)
        host.addSubview(mediaView)
        host.addSubview(quickLookView)

        XCTAssertTrue(pdfView === sessions.pdf.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(pdfView.superview)

        XCTAssertTrue(imageView === sessions.image.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(imageView.superview)

        XCTAssertTrue(mediaView === sessions.media.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(mediaView.superview)

        let remountedQuickLookView = sessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        XCTAssertFalse(quickLookView === remountedQuickLookView)
        XCTAssertTrue(quickLookView.superview === host)
        sessions.quickLook.dismantle(quickLookView)
        XCTAssertNil(quickLookView.superview)
    }

    @Test func testSaveTextContentWritesLiveTextViewContent() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        let textView = NSTextView()
        textView.string = "edited from text view"
        panel.attachTextView(textView)

        let task = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)
        await task.value

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited from text view")
        XCTAssertEqual(panel.textContent, "edited from text view")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    @Test func testSaveTextContentIgnoresConcurrentSaveRequest() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("first save")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)

        let firstSave = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)

        panel.updateTextContent("second save")
        XCTAssertNil(panel.saveTextContent())

        let pipeRead = Task.detached { () throws -> String in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return String(data: handle.availableData, encoding: .utf8) ?? ""
        }

        let savedContent = try await pipeRead.value
        XCTAssertEqual(savedContent, "first save")
        await firstSave.value

        XCTAssertEqual(panel.textContent, "second save")
        XCTAssertTrue(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    @MainActor
    @Test func testMarkdownNoteSaveCompletionDoesNotClearDirtyAfterRelocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDir = root.appendingPathComponent(".cmux/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldURL = notesDir.appendingPathComponent("old.md")
        let newURL = notesDir.appendingPathComponent("new.md")
        try "original".write(to: oldURL, atomically: true, encoding: .utf8)
        try "original".write(to: newURL, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: oldURL.path)
        defer { panel.close() }
        panel.updateTextContent("edited")
        try FileManager.default.removeItem(at: oldURL)
        XCTAssertEqual(mkfifo(oldURL.path, 0o600), 0)

        let save = try XCTUnwrap(panel.saveTextContent())
        NotificationCenter.default.post(
            name: .cmuxNoteFileRelocated,
            object: nil,
            userInfo: ["oldPath": oldURL.path, "newPath": newURL.path]
        )
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(panel.filePath, newURL.path)

        let pipeRead = Task.detached { () throws -> String in
            let handle = try FileHandle(forReadingFrom: oldURL)
            defer { try? handle.close() }
            return String(data: handle.availableData, encoding: .utf8) ?? ""
        }
        let oldPipeContent = try await pipeRead.value
        XCTAssertEqual(oldPipeContent, "edited")
        await save.value

        XCTAssertTrue(panel.isDirty)
        XCTAssertFalse(panel.isSaving)

        let resave = try XCTUnwrap(panel.saveTextContent())
        await resave.value
        XCTAssertEqual(try String(contentsOf: newURL, encoding: .utf8), "edited")
        XCTAssertFalse(panel.isDirty)
    }

    @Test func testCleanSaveDoesNotCancelPendingTextLoad() async throws {
        let url = try temporaryTextFile(contents: "", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        try "loaded after clean save".write(to: url, atomically: true, encoding: .utf8)

        let loadTask = panel.loadTextContent()
        XCTAssertNil(panel.saveTextContent())
        await loadTask.value

        XCTAssertEqual(panel.textContent, "loaded after clean save")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
    }

    @Test func testSavingTextViewUsesConfiguredSaveShortcut() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "saved by configured shortcut"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "u",
            charactersIgnoringModifiers: "u",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_U)
        ))

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        await waitForPanelSave(panel)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved by configured shortcut")
    }

    @Test func testSavingTextViewDoesNotUseDefaultSaveShortcutAfterRemap() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "should not save through command s"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_S)
        ))

        XCTAssertFalse(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    @Test func testSaveTextContentPreservesLoadedEncoding() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        if let task = panel.saveTextContent() {
            await task.value
        }

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf16), "edited")
        XCTAssertFalse(panel.isDirty)
    }

    @Test func testTrustedWorkspaceNoteSavePreservesOriginalWhenAtomicTempCannotBeCreated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDir = root.appendingPathComponent(".cmux/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        defer {
            _ = chmod(notesDir.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        let noteURL = notesDir.appendingPathComponent("note.md")
        try "original".write(to: noteURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(notesDir.path, 0o500), 0)

        let result = await FilePreviewTextSaver.saveTrustedWorkspaceNote(
            content: "edited",
            to: noteURL,
            encoding: .utf8
        )
        guard case .failed(let fileExists) = result else {
            XCTFail("Expected trusted note save to fail")
            return
        }
        XCTAssertTrue(fileExists)
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "original")
    }

    @Test func testSaveTextContentWritesThroughSymlink() async throws {
        let targetURL = try temporaryTextFile(contents: "original", encoding: .utf8)
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: linkURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited through link")
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "edited through link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), targetURL.path)
        XCTAssertFalse(panel.isDirty)
    }

    @Test func testCleanSaveDoesNotWriteReadOnlyTextFile() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    @Test func testLoadTextContentClearsDirtyStateWhenFileVanishes() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        try FileManager.default.removeItem(at: url)

        await panel.loadTextContent().value

        XCTAssertEqual(panel.textContent, "")
        XCTAssertFalse(panel.isDirty)
        XCTAssertTrue(panel.isFileUnavailable)
    }

    @Test func testTextEditorInsetsReapplyWhenMovedBetweenWindows() {
        _ = NSApplication.shared
        let textView = SavingTextView()
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let firstWindow = windowHosting(textView)
        defer { closeWindow(firstWindow) }
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let secondWindow = windowHosting(textView)
        defer { closeWindow(secondWindow) }
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        withExtendedLifetime([firstWindow, secondWindow]) {}
    }

    @Test func testTextEditorClearThemeDoesNotDrawAppKitBackgrounds() {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView()
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: .clear,
            foregroundColor: .white,
            drawsBackground: false
        )

        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertFalse(scrollView.contentView.drawsBackground)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertEqual(scrollView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(scrollView.contentView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(textView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(textView.textColor, .white)
        XCTAssertEqual(textView.insertionPointColor, .white)
    }

    @Test func testTextEditorOpaqueThemeDrawsAppKitBackgrounds() {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView()
        let backgroundColor = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: backgroundColor,
            foregroundColor: .white,
            drawsBackground: true
        )

        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertTrue(scrollView.contentView.drawsBackground)
        XCTAssertTrue(textView.drawsBackground)
        XCTAssertEqual(scrollView.backgroundColor, backgroundColor)
        XCTAssertEqual(scrollView.contentView.backgroundColor, backgroundColor)
        XCTAssertEqual(textView.backgroundColor, backgroundColor)
        XCTAssertEqual(scrollView.backgroundColor.alphaComponent, 1)
        XCTAssertEqual(scrollView.contentView.backgroundColor.alphaComponent, 1)
        XCTAssertEqual(textView.backgroundColor.alphaComponent, 1)
    }

    @Test func testTextEditorLineNumberRulerCanBeEnabledForMarkdownEditors() {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.configureLineNumberRuler(
            on: scrollView,
            textView: textView,
            showsLineNumbers: true,
            backgroundColor: .black,
            foregroundColor: .white,
            drawsBackground: true
        )

        XCTAssertTrue(scrollView.hasVerticalRuler)
        XCTAssertTrue(scrollView.rulersVisible)
        XCTAssertTrue(scrollView.verticalRulerView is FilePreviewLineNumberRulerView)

        FilePreviewTextEditor<FilePreviewPanel>.configureLineNumberRuler(
            on: scrollView,
            textView: textView,
            showsLineNumbers: false,
            backgroundColor: .black,
            foregroundColor: .white,
            drawsBackground: true
        )

        XCTAssertFalse(scrollView.hasVerticalRuler)
        XCTAssertFalse(scrollView.rulersVisible)
        XCTAssertNil(scrollView.verticalRulerView)
    }

    @Test func testWordWrapWidthAccountsForLineNumberGutter() throws {
        _ = NSApplication.shared
        // The ruler only claims tile space once the scroll view lives in a
        // window, so host it like the real editor.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.close()
        }
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.configureLineNumberRuler(
            on: scrollView,
            textView: textView,
            showsLineNumbers: true,
            backgroundColor: .black,
            foregroundColor: .white,
            drawsBackground: true
        )
        scrollView.tile()
        window.contentView?.layoutSubtreeIfNeeded()

        // The gutter must actually consume horizontal space for this test to
        // mean anything.
        let clipWidth = scrollView.contentView.frame.width
        XCTAssertLessThan(clipWidth, scrollView.frame.width)

        textView.applyFilePreviewWordWrap(true, scrollView: scrollView)

        // Soft wrap must break lines at the visible clip width, not at the
        // ruler-inclusive scroll view width — otherwise text runs under the
        // right edge whenever the line-number gutter is showing.
        XCTAssertEqual(textView.frame.width, clipWidth)
        let containerWidth = try XCTUnwrap(textView.textContainer?.size.width)
        XCTAssertTrue(containerWidth <= clipWidth)
    }

    @Test func testLineNumberRulerTracksTextStorageEditsIncrementally() throws {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.configureLineNumberRuler(
            on: scrollView,
            textView: textView,
            showsLineNumbers: true,
            backgroundColor: .black,
            foregroundColor: .white,
            drawsBackground: true
        )
        let ruler = try XCTUnwrap(scrollView.verticalRulerView as? FilePreviewLineNumberRulerView)
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertTrue(ruler.isTrackingTextStorage(storage))

        func naiveLineStarts(_ text: String) -> [Int] {
            var starts = [0]
            var index = 0
            for codeUnit in text.utf16 {
                index += 1
                if codeUnit == 10 { starts.append(index) }
            }
            return starts
        }

        textView.string = "alpha\nbeta\ngamma"
        ruler.rebuildLineStartsIfNeeded()
        XCTAssertEqual(ruler.lineStarts, [0, 6, 11])

        // Every subsequent edit goes through the incremental text-storage
        // path with no full invalidation in between; the cache must keep
        // matching a naive whole-document rescan.
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "X")
        XCTAssertEqual(ruler.lineStarts, naiveLineStarts(textView.string))

        storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "one\ntwo\n")
        XCTAssertEqual(ruler.lineStarts, naiveLineStarts(textView.string))

        storage.replaceCharacters(in: NSRange(location: 2, length: 9), with: "")
        XCTAssertEqual(ruler.lineStarts, naiveLineStarts(textView.string))

        storage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "a\nb")
        XCTAssertEqual(ruler.lineStarts, naiveLineStarts(textView.string))

        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\ntail\n")
        XCTAssertEqual(ruler.lineStarts, naiveLineStarts(textView.string))

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "solo")
        XCTAssertEqual(ruler.lineStarts, [0])
    }

    @Test func testPendingTextFocusAppliesWhenTextViewAttaches() throws {
        _ = NSApplication.shared
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        panel.focus()

        let textView = SavingTextView()
        let window = windowHosting(textView)
        defer { closeWindow(window) }
        panel.attachTextView(textView)

        XCTAssertTrue(window.firstResponder === textView)
        withExtendedLifetime(window) {}
    }

    @Test func testPDFExtensionWinsOverLooseTextSniff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .pdf)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.richtext")
    }

    @Test func testUTF16TextWithBOMStillResolvesAsText() throws {
        let url = try temporaryTextFile(contents: "hello", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.text")
    }

    @Test func testExtensionlessTextFileResolvesToTextAfterFastInitialClassification() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "extensionless text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await waitForPanelPreviewMode(panel, .text)
        await waitForPanelTextContent(panel, "extensionless text")

        XCTAssertEqual(panel.displayIcon, "doc.text")
    }

    @Test func testBinaryPlistDoesNotOpenAsEditableText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("bplist00".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertNotEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    @Test func testExternalOpenApplicationResolverOrdersDefaultAppFirstAndDeduplicates() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.mov")
        let quickTimeURL = URL(fileURLWithPath: "/Applications/QuickTime Player.app")
        let vlcURL = URL(fileURLWithPath: "/Applications/VLC.app")
        let names = [
            quickTimeURL.path: "QuickTime Player",
            vlcURL.path: "VLC",
        ]
        let resolver = FileExternalOpenApplicationResolver(
            defaultApplicationURL: { _ in quickTimeURL },
            applicationURLs: { _ in [vlcURL, quickTimeURL, vlcURL] },
            displayName: { names[$0.path] ?? $0.lastPathComponent },
            shouldIncludeApplication: { _ in true }
        )

        let applications = resolver.applications(for: fileURL)

        XCTAssertEqual(applications.map(\.displayName), ["QuickTime Player", "VLC"])
        XCTAssertEqual(applications.map(\.isDefault), [true, false])
    }

    @Test func testExternalOpenApplicationResolverFallsBackWhenDefaultAppIsFiltered() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.pdf")
        let cmuxURL = URL(fileURLWithPath: "/Applications/cmux.app")
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let resolver = FileExternalOpenApplicationResolver(
            defaultApplicationURL: { _ in cmuxURL },
            applicationURLs: { _ in [cmuxURL, previewURL] },
            displayName: { $0.deletingPathExtension().lastPathComponent },
            shouldIncludeApplication: { $0 != cmuxURL }
        )

        let applications = resolver.applications(for: fileURL)

        XCTAssertEqual(applications.map(\.displayName), ["Preview"])
        XCTAssertEqual(applications.map(\.isDefault), [false])
    }

    @Test func testExternalOpenMenuKeepsFinderTopLevelAndOpenWithItemsSearchableByAppName() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.png")
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let pixelmatorURL = URL(fileURLWithPath: "/Applications/Pixelmator Pro.app")
        let primaryApplication = FileExternalOpenApplication(
            url: previewURL,
            displayName: "Preview",
            isDefault: true
        )
        let otherApplication = FileExternalOpenApplication(
            url: pixelmatorURL,
            displayName: "Pixelmator Pro",
            isDefault: false
        )

        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: primaryApplication,
            otherApplications: [otherApplication]
        )

        let topLevelTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(topLevelTitles, [
            FileExternalOpenText.openInApplication("Preview"),
            FileExternalOpenText.revealInFinder,
            FileExternalOpenText.openWithMenu,
        ])

        let openWithItem = try XCTUnwrap(menu.items.first { $0.title == FileExternalOpenText.openWithMenu })
        let openWithTitles = try XCTUnwrap(openWithItem.submenu?.items.map(\.title))
        XCTAssertEqual(openWithTitles, ["Pixelmator Pro"])
    }

    @Test func testExternalOpenMenuKeepsFinderTopLevelWithoutResolvedApplications() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.bin")

        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: nil,
            otherApplications: []
        )

        let topLevelTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(topLevelTitles, [
            FileExternalOpenText.openExternally,
            FileExternalOpenText.revealInFinder,
        ])
    }

    @Test func testCmdClickSupportedFileRoutingDefaultsToReadableRegularFilesOnly() throws {
        let suiteName = "cmux.file-preview-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "preview me", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        XCTAssertTrue(FileRouteSettingsStore(defaults: defaults).supportedFileRouteEnabled)
        XCTAssertTrue(FileRouteSettingsStore(defaults: defaults).shouldRouteSupportedFile(path: fileURL.path))
        XCTAssertFalse(FileRouteSettingsStore(defaults: defaults).shouldRouteSupportedFile(path: directoryURL.path))

        defaults.set(false, forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey)
        XCTAssertFalse(FileRouteSettingsStore(defaults: defaults).shouldRouteSupportedFile(path: fileURL.path))
    }

    @Test func testCmdClickMarkdownRoutingDoesNotRequireSupportedFileRoutingSetting() throws {
        let suiteName = "cmux.markdown-preview-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "# preview me", encoding: .utf8, pathExtension: "md")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        defaults.set(true, forKey: AppCatalogSection().openMarkdownInCmuxViewer.userDefaultsKey)
        defaults.set(false, forKey: AppCatalogSection().openSupportedFilesInCmux.userDefaultsKey)

        XCTAssertTrue(FileRouteSettingsStore(defaults: defaults).shouldRouteMarkdown(path: fileURL.path))
        XCTAssertFalse(FileRouteSettingsStore(defaults: defaults).shouldRouteSupportedFile(path: fileURL.path))
    }

    @Test func testCmdClickMarkdownRoutingDefaultsToReadableMarkdownFiles() throws {
        let suiteName = "cmux.markdown-preview-default-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "# preview me", encoding: .utf8, pathExtension: "md")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(FileRouteSettingsStore(defaults: defaults).markdownRouteEnabled)
        XCTAssertTrue(FileRouteSettingsStore(defaults: defaults).shouldRouteMarkdown(path: fileURL.path))
    }

    @Test func testCmdClickFilePreviewRoutingReusesRightSidePane() throws {
        let sourceURL = try temporaryTextFile(contents: "source", encoding: .utf8)
        let firstURL = try temporaryTextFile(contents: "first", encoding: .utf8)
        let secondURL = try temporaryTextFile(contents: "second", encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: sourcePane,
            filePath: sourceURL.path,
            focus: true
        ))

        let firstPanel = try XCTUnwrap(workspace.openOrFocusFilePreviewSplit(
            from: sourcePanel.id,
            filePath: firstURL.path
        ))
        let rightPane = try XCTUnwrap(workspace.paneId(forPanelId: firstPanel.id))
        let paneCountAfterFirstOpen = workspace.bonsplitController.allPaneIds.count
        let rightTabsAfterFirstOpen = workspace.bonsplitController.tabs(inPane: rightPane).count

        let secondPanel = try XCTUnwrap(workspace.openOrFocusFilePreviewSplit(
            from: sourcePanel.id,
            filePath: secondURL.path
        ))

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, paneCountAfterFirstOpen)
        XCTAssertEqual(workspace.paneId(forPanelId: secondPanel.id)?.id, rightPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: rightPane).count, rightTabsAfterFirstOpen + 1)
    }

    @Test func testCmdClickMarkdownRoutingReusesRightSidePane() throws {
        let sourceURL = try temporaryTextFile(contents: "source", encoding: .utf8)
        let firstURL = try temporaryTextFile(contents: "# first", encoding: .utf8, pathExtension: "md")
        let secondURL = try temporaryTextFile(contents: "# second", encoding: .utf8, pathExtension: "md")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: sourcePane,
            filePath: sourceURL.path,
            focus: true
        ))

        let firstPanel = try XCTUnwrap(workspace.openOrFocusMarkdownSplit(
            from: sourcePanel.id,
            filePath: firstURL.path
        ))
        let rightPane = try XCTUnwrap(workspace.paneId(forPanelId: firstPanel.id))
        let paneCountAfterFirstOpen = workspace.bonsplitController.allPaneIds.count
        let rightTabsAfterFirstOpen = workspace.bonsplitController.tabs(inPane: rightPane).count

        let secondPanel = try XCTUnwrap(workspace.openOrFocusMarkdownSplit(
            from: sourcePanel.id,
            filePath: secondURL.path
        ))

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, paneCountAfterFirstOpen)
        XCTAssertEqual(workspace.paneId(forPanelId: secondPanel.id)?.id, rightPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: rightPane).count, rightTabsAfterFirstOpen + 1)
    }

    private func temporaryTextFile(
        contents: String,
        encoding: String.Encoding,
        pathExtension: String = "txt"
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func waitForPanelSave(
        _ panel: FilePreviewPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if !panel.isSaving {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview save", file: file, line: line)
    }

    private func waitForPanelPreviewMode(
        _ panel: FilePreviewPanel,
        _ mode: FilePreviewMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.previewMode == mode {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview mode", file: file, line: line)
    }

    private func waitForPanelTextContent(
        _ panel: FilePreviewPanel,
        _ content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.textContent == content {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview text content", file: file, line: line)
    }

    private func closeWindow(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func windowHosting(_ textView: NSTextView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)
        scrollView.documentView = textView
        return window
    }
}


@MainActor
@Suite(.serialized)
final class BonsplitTabDragPayloadTests {
    @Test func testRejectsFilePreviewCompatibilityPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview", includesFilePreviewTransferType: true)

        XCTAssertNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Sidebar workspace drop targets should ignore file-preview drags instead of treating them as movable tabs"
        )
    }

    @Test func testAcceptsRealFilePreviewTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview")

        XCTAssertNotNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Existing file-preview tabs should still move through normal Bonsplit tab drag paths"
        )
    }

    @Test func testAcceptsRegularCurrentProcessTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: nil)

        XCTAssertNotNil(BonsplitTabDragPayload.transfer(from: pasteboard))
    }

    @Test func testWorkspaceDropRoutingAcceptsTabTransferTypeOnly() {
        XCTAssertTrue(
            BonsplitTabDragPayload.canRouteWorkspaceDrop(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType]
            )
        )
    }

    @Test func testWorkspaceDropRoutingRejectsFilePreviewCompatibilityTransfer() {
        XCTAssertFalse(
            BonsplitTabDragPayload.canRouteWorkspaceDrop(
                pasteboardTypes: [
                    DragOverlayRoutingPolicy.filePreviewTransferType,
                    DragOverlayRoutingPolicy.bonsplitTabTransferType,
                ]
            )
        )
    }

    private func makeBonsplitPayloadPasteboard(
        kind: String?,
        includesFilePreviewTransferType: Bool = false
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.bonsplit.\(UUID().uuidString)"))
        pasteboard.clearContents()

        var tab: [String: Any] = ["id": UUID().uuidString]
        if let kind {
            tab["kind"] = kind
        }
        let payload: [String: Any] = [
            "tab": tab,
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier))
        if includesFilePreviewTransferType {
            pasteboard.setData(data, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
        }
        return pasteboard
    }
}

@MainActor
@Suite(.serialized)
final class TmuxWorkspacePaneOverlayTests {
    @Test func testTmuxWorkspacePaneOverlayModelTracksFlashReason() {
        let model = TmuxWorkspacePaneOverlayModel()
        let initialState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 1,
            flashReason: .notificationArrival
        )
        let laterState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: initialState.workspaceId,
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 2,
            flashReason: .navigation
        )

        model.apply(initialState)
        model.apply(laterState)

        XCTAssertEqual(model.flashReason, .navigation)
    }

    @Test func testTmuxWorkspacePaneOverlayModelAnimatesFlashAfterWorkspaceSwitchBackWhenTokenChanges() {
        let model = TmuxWorkspacePaneOverlayModel()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let firstFlashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [firstFlashRect],
            flashRect: firstFlashRect,
            flashToken: 0,
            flashReason: nil
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: secondWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 0,
            flashReason: nil
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: firstWorkspaceId,
                unreadRects: [],
                flashRect: firstFlashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    @Test func testTmuxWorkspacePaneOverlayModelWaitsForFlashRectBeforeConsumingToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let firstFlashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [],
            flashRect: firstFlashRect,
            flashToken: 0,
            flashReason: nil
        ))
        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: secondWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 0,
            flashReason: nil
        ))

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 1,
            flashReason: .unreadIndicatorDismiss
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: firstWorkspaceId,
                unreadRects: [],
                flashRect: firstFlashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    @Test func testTmuxWorkspacePaneOverlayModelAnimatesFirstObservedFlashToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let workspaceId = UUID()
        let flashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspaceId,
                unreadRects: [],
                flashRect: flashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    @Test func testTmuxWorkspacePaneOverlayModelWaitsForRectBeforeFirstObservedFlashToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let workspaceId = UUID()
        let flashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 1,
            flashReason: .unreadIndicatorDismiss
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspaceId,
                unreadRects: [],
                flashRect: flashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    @Test func testAllFlashReasonsUseNotificationRingAccent() {
        let reasons: [WorkspaceAttentionFlashReason] = [
            .navigation,
            .notificationArrival,
            .notificationDismiss,
            .unreadIndicatorDismiss,
            .debug,
        ]

        for reason in reasons {
            XCTAssertEqual(
                WorkspaceAttentionCoordinator.flashStyle(for: reason).accent,
                WorkspaceAttentionCoordinator.notificationRingStyle.accent
            )
        }
    }

    @Test func testFocusFlashUsesNotificationRingColor() {
        XCTAssertEqual(
            WorkspaceAttentionCoordinator.flashStyle(for: .navigation).accent.strokeColor.hexString(),
            WorkspaceAttentionCoordinator.notificationRingStyle.accent.strokeColor.hexString()
        )
    }

    @Test func testTmuxWorkspacePaneExactRectReturnsContentRelativeFrameForDescendantView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected contentView")
            return
        }

        let targetView = NSView(frame: NSRect(x: 120, y: 48, width: 300, height: 200))
        contentView.addSubview(targetView)

        XCTAssertEqual(
            ContentView.tmuxWorkspacePaneExactRect(for: targetView, in: contentView),
            CGRect(x: 120, y: 48, width: 300, height: 200)
        )
    }
}
#endif
