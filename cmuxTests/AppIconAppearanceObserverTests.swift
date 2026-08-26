import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual == expected, Comment(rawValue: message))
}

private func checkTrue(_ condition: @autoclosure () -> Bool, _ message: String = "") {
    #expect(condition(), Comment(rawValue: message))
}

@Suite
struct AppIconAppearanceObserverTests {
    private final class ObservationToken: EffectiveAppearanceObservation {
        private(set) var invalidateCallCount = 0

        func invalidate() {
            invalidateCallCount += 1
        }
    }

    private final class Harness {
        var isFinishedLaunching = false
        var isDark = false
        var startObservationCallCount = 0
        var currentAppearanceIsDarkCallCount = 0
        var imageRequests: [String] = []
        var appliedIconCount = 0
        var didFinishLaunchingObserverCount = 0
        private(set) var didFinishLaunchingHandler: (() -> Void)?
        private(set) var appearanceHandler: (() -> Void)?
        let observation = ObservationToken()

        lazy var environment = AppIconAppearanceObserver.Environment(
            isApplicationFinishedLaunching: { [unowned self] in
                self.isFinishedLaunching
            },
            startEffectiveAppearanceObservation: { [unowned self] handler in
                self.startObservationCallCount += 1
                self.appearanceHandler = handler
                return self.observation
            },
            addDidFinishLaunchingObserver: { [unowned self] handler in
                self.didFinishLaunchingObserverCount += 1
                self.didFinishLaunchingHandler = handler
                return NSObject()
            },
            removeObserver: { _ in },
            currentAppearanceIsDark: { [unowned self] in
                self.currentAppearanceIsDarkCallCount += 1
                return self.isDark
            },
            imageForName: { [unowned self] imageName in
                self.imageRequests.append(imageName)
                return NSImage(size: NSSize(width: 1, height: 1))
            },
            setApplicationIconImage: { [unowned self] _ in
                self.appliedIconCount += 1
            }
        )

        func fireDidFinishLaunching() {
            didFinishLaunchingHandler?()
        }

        func fireAppearanceChanged() {
            appearanceHandler?()
        }
    }

    @Test
    func testStartObservingDefersInitialApplyUntilLaunch() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()

        checkEqual(harness.didFinishLaunchingObserverCount, 1)
        checkEqual(harness.startObservationCallCount, 0)
        checkEqual(harness.currentAppearanceIsDarkCallCount, 0)
        checkTrue(harness.imageRequests.isEmpty)

        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()

        checkEqual(harness.startObservationCallCount, 1)
        checkEqual(harness.currentAppearanceIsDarkCallCount, 1)
        checkEqual(harness.imageRequests, ["AppIconLight"])
        checkEqual(harness.appliedIconCount, 1)
    }

    @Test
    func testStopObservingCancelsDeferredLaunchApply() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()
        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()

        checkEqual(harness.startObservationCallCount, 0)
        checkEqual(harness.currentAppearanceIsDarkCallCount, 0)
        checkTrue(harness.imageRequests.isEmpty)
        checkEqual(harness.appliedIconCount, 0)
    }

    @Test
    func testStopObservingInvalidatesActiveObservation() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()

        checkEqual(harness.startObservationCallCount, 1)
        checkEqual(harness.observation.invalidateCallCount, 1)
    }

    @Test
    func testUnchangedAutomaticAppearanceDoesNotReapplyIcon() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.fireAppearanceChanged()

        checkEqual(harness.currentAppearanceIsDarkCallCount, 2)
        checkEqual(harness.imageRequests, ["AppIconLight"])
        checkEqual(harness.appliedIconCount, 1)
    }

    @Test
    func testAutomaticAppearanceChangeAppliesNewIcon() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.isDark = true
        harness.fireAppearanceChanged()

        checkEqual(harness.imageRequests, ["AppIconLight", "AppIconDark"])
        checkEqual(harness.appliedIconCount, 2)
    }

    @Test
    func testCustomImagePathValidationResolvesRelativeImageAndRejectsUnsafeSVG() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-app-icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("cmux.json")
        let imageURL = directory.appendingPathComponent("icon.png")
        let pngData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try pngData.write(to: imageURL)

        let prepared = CmuxValidatedImageAsset.prepare(
            "icon.png",
            relativeToConfig: configURL.path,
            globalConfigPath: configURL.path
        )
        guard case .success(let asset) = prepared else {
            Issue.record("A valid relative PNG should pass custom app-icon validation: \(prepared)")
            return
        }
        #expect(asset.resolvedPath == imageURL.standardizedFileURL.path)
        #expect(AppIconImageResolver.image(for: imageURL.path) != nil)

        let validSVGURL = directory.appendingPathComponent("valid.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Hello</text></svg>"
            .write(to: validSVGURL, atomically: true, encoding: .utf8)
        let validSVG = CmuxValidatedImageAsset.prepare(
            validSVGURL.path,
            relativeToConfig: configURL.path,
            globalConfigPath: configURL.path
        )
        guard case .success = validSVG else {
            Issue.record("A valid SVG with text content should pass custom app-icon validation: \(validSVG)")
            return
        }

        let unsafeSVGURL = directory.appendingPathComponent("unsafe.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"
            .write(to: unsafeSVGURL, atomically: true, encoding: .utf8)
        let unsafe = CmuxValidatedImageAsset.prepare(
            unsafeSVGURL.path,
            relativeToConfig: configURL.path,
            globalConfigPath: configURL.path
        )
        #expect(unsafe == .failure(.unsafeSVG))
    }

    @Test
    func testCustomImagePathValidationRejectsOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-app-icon-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("large.png")
        try Data(repeating: 0, count: CmuxValidatedImageAsset.maxImageBytes + 1).write(to: imageURL)
        let result = CmuxValidatedImageAsset.prepare(
            imageURL.path,
            relativeToConfig: nil,
            globalConfigPath: AppIconImageResolver.defaultConfigPath
        )
        #expect(result == .failure(.tooLarge))
    }

    @Test
    @MainActor
    func testCustomImageSelectionOverridesBuiltInMode() throws {
        let suiteName = "AppIconAppearanceObserverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/tmp/custom-icon.png", forKey: AppIconSettings.imagePathKey)
        defaults.set(AppIconMode.dark.rawValue, forKey: AppIconSettings.modeKey)

        let expectedIcon = NSImage(size: NSSize(width: 16, height: 16))
        var receivedIcon: NSImage?
        var requestedPath: String?
        var stopCount = 0
        var fallbackModeRequests = 0
        var notificationCount = 0
        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { _ in
                fallbackModeRequests += 1
                return nil
            },
            imageForPath: { path in
                requestedPath = path
                return expectedIcon
            },
            setApplicationIconImage: { receivedIcon = $0 },
            startAppearanceObservation: {},
            stopAppearanceObservation: { stopCount += 1 },
            notifyDockTilePlugin: { notificationCount += 1 }
        )

        AppIconSettings.applyCurrentIcon(defaults: defaults, environment: environment)

        #expect(requestedPath == "/tmp/custom-icon.png")
        #expect(receivedIcon === expectedIcon)
        #expect(stopCount == 1)
        #expect(fallbackModeRequests == 0)
        #expect(notificationCount == 1)
    }
}
