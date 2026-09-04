import AppKit
import CmuxFoundation
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
    func testCustomImagePathValidationResolvesRelativeImageAndRejectsUnsafeSVG() async throws {
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
        #expect(AppIconImageResolver.image(
            for: "icon.png",
            relativeToConfig: configURL.path
        ) != nil)
        #expect(await AppIconImageResolver.isValid(
            for: "icon.png",
            relativeToConfig: configURL.path
        ))

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
        #expect(!(await AppIconImageResolver.isValid(
            for: unsafeSVGURL.path,
            relativeToConfig: configURL.path
        )))
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
    func testEquivalentGlobalConfigPathsDoNotMarkImageAsProjectLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-app-icon-global-path-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigPath = globalDirectory.appendingPathComponent("cmux.json").path
        let equivalentConfigPath = globalDirectory.path + "/./cmux.json"
        let iconPath = globalDirectory.appendingPathComponent("safe.svg")
        let data = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><circle/></svg>".utf8)
        try data.write(to: iconPath)

        let icon = CmuxButtonIcon.imagePath("safe.svg")
        #expect(
            icon.bonsplitIcon(
                configSourcePath: equivalentConfigPath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalImage: false
            ) == .imageData(data)
        )
        #expect(
            icon.projectLocalImageFingerprint(
                configSourcePath: equivalentConfigPath,
                globalConfigPath: globalConfigPath
            ) == nil
        )
    }

    @Test
    func testCustomImagePathValidationRejectsNamespacedAndEscapedSVGContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-app-icon-svg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unsafeSVGs = [
            (
                "prefixed-script.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:svg=\"http://www.w3.org/2000/svg\"><svg:script>alert(1)</svg:script></svg>"
            ),
            (
                "prefixed-style.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:svg=\"http://www.w3.org/2000/svg\"><svg:style>@\\69mport '//example.com/theme.css';</svg:style></svg>"
            ),
            (
                "escaped-import.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>@\\69mport '//example.com/theme.css';</style></svg>"
            ),
            (
                "escaped-url.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect style=\"fill:u\\72l(//example.com/icon.svg#mark)\"/></svg>"
            ),
        ]

        for (fileName, source) in unsafeSVGs {
            let imageURL = directory.appendingPathComponent(fileName)
            try source.write(to: imageURL, atomically: true, encoding: .utf8)
            let result = CmuxValidatedImageAsset.prepare(
                imageURL.path,
                relativeToConfig: nil,
                globalConfigPath: AppIconImageResolver.defaultConfigPath
            )
            #expect(
                result == .failure(.unsafeSVG),
                "Expected \(fileName) to be rejected, got \(result)"
            )
        }
    }

    @Test
    func testCustomImageRejectionLogsDoNotExposePaths() throws {
        let privatePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("Private Project \(UUID().uuidString)")
            .appendingPathComponent("missing-icon.png")
            .path
        var messages: [String] = []

        #expect(AppIconImageResolver.image(
            for: privatePath,
            relativeToConfig: nil,
            log: { messages.append($0) }
        ) == nil)
        #expect(messages.count == 1)
        #expect(!messages.joined().contains(privatePath))

        let invalidImageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Private Invalid Icon \(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: invalidImageURL) }
        try Data("not an image".utf8).write(to: invalidImageURL)
        messages.removeAll()

        #expect(AppIconImageResolver.image(
            for: invalidImageURL.path,
            relativeToConfig: nil,
            log: { messages.append($0) }
        ) == nil)
        #expect(messages.count == 1)
        #expect(!messages.joined().contains(invalidImageURL.path))
    }

    @Test
    @MainActor
    func testCustomImageSelectionOverridesBuiltInMode() async throws {
        let suiteName = "AppIconAppearanceObserverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("/tmp/custom-icon.png", forKey: AppIconSettings.imagePathKey)
        defaults.set(AppIconMode.dark.rawValue, forKey: AppIconSettings.modeKey)

        let expectedIcon = NSImage(size: NSSize(width: 16, height: 16))
        var stopCount = 0
        var fallbackModeRequests = 0
        var notificationCount = 0
        let prepared = AppIconImageResolver.PreparedImage(image: expectedIcon)
        let application = AppIconSettingsApplication()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let environment = AppIconSettings.Environment(
                isApplicationFinishedLaunching: { true },
                imageForMode: { _ in
                    fallbackModeRequests += 1
                    return nil
                },
                prepareImageForPath: { requestedPath in
                    #expect(requestedPath == "/tmp/custom-icon.png")
                    return prepared
                },
                setApplicationIconImage: { icon in
                    #expect(icon === expectedIcon)
                    continuation.resume()
                },
                startAppearanceObservation: {},
                stopAppearanceObservation: { stopCount += 1 },
                notifyDockTilePlugin: { notificationCount += 1 }
            )

            AppIconSettings.applyCurrentIcon(
                defaults: defaults,
                environment: environment,
                application: application
            )
        }

        #expect(stopCount == 1)
        #expect(fallbackModeRequests == 0)
        #expect(notificationCount == 1)
    }

    @Test(.timeLimit(.seconds(10)))
    @MainActor
    func testReplacingCustomImageCancelsOlderResolution() async throws {
        let suiteName = "AppIconAppearanceObserverTests.cancellation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstPath = "/tmp/first-custom-icon.png"
        let secondPath = "/tmp/second-custom-icon.png"
        defaults.set(firstPath, forKey: AppIconSettings.imagePathKey)

        let firstStarted = AsyncStream<Void>.makeStream()
        let firstCancelled = AsyncStream<Void>.makeStream()
        let firstRelease = AsyncStream<Void>.makeStream()
        let secondApplied = AsyncStream<Void>.makeStream()
        defer {
            firstStarted.continuation.finish()
            firstCancelled.continuation.finish()
            firstRelease.continuation.finish()
            secondApplied.continuation.finish()
        }
        var firstStartedIterator = firstStarted.stream.makeAsyncIterator()
        var firstCancelledIterator = firstCancelled.stream.makeAsyncIterator()
        var secondAppliedIterator = secondApplied.stream.makeAsyncIterator()

        let firstIcon = NSImage(size: NSSize(width: 16, height: 16))
        let secondIcon = NSImage(size: NSSize(width: 32, height: 32))
        let firstPrepared = AppIconImageResolver.PreparedImage(image: firstIcon)
        let secondPrepared = AppIconImageResolver.PreparedImage(image: secondIcon)
        let application = AppIconSettingsApplication()
        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { _ in nil },
            prepareImageForPath: { path in
                guard path == firstPath else { return secondPrepared }
                firstStarted.continuation.yield()
                return await withTaskCancellationHandler {
                    for await _ in firstRelease.stream { return firstPrepared }
                    return firstPrepared
                } onCancel: {
                    firstCancelled.continuation.yield()
                    firstRelease.continuation.finish()
                }
            },
            setApplicationIconImage: { icon in
                if icon === firstIcon {
                    Issue.record("A cancelled resolution must not apply its stale icon")
                } else if icon === secondIcon {
                    secondApplied.continuation.yield()
                }
            },
            startAppearanceObservation: {},
            stopAppearanceObservation: {},
            notifyDockTilePlugin: {}
        )

        application.applyCurrentIcon(defaults: defaults, environment: environment)
        _ = await firstStartedIterator.next()
        defaults.set(secondPath, forKey: AppIconSettings.imagePathKey)
        application.applyCurrentIcon(defaults: defaults, environment: environment)

        _ = await firstCancelledIterator.next()
        _ = await secondAppliedIterator.next()
    }
}
