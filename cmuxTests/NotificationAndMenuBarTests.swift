import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Thread-safe one-shot holder for a policy-evaluation result. Lets a test
/// detect a stalled evaluation by reading the stored value after a timeout,
/// instead of awaiting (and hanging on) the evaluation `Task` itself when the
/// hook never completes.
private final class NotificationHookEvaluationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>?

    func store(_ value: Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }

    func take() -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class TerminalNotificationPolicyEngineTests: XCTestCase {
    private func evaluate(
        request: TerminalNotificationPolicyRequest,
        hooks: [CmuxResolvedNotificationHook]
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        await TerminalNotificationPolicyEngine.evaluate(
            request: request,
            hooks: hooks
        )
    }

    func testHookCanDisableDesktopAndTransformBody() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Title",
            subtitle: "Subtitle",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "filter",
            command: #"sed 's/"desktop":true/"desktop":false/; s/"body":"Body"/"body":"Filtered"/'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        let envelope = try result.get()
        XCTAssertFalse(envelope.effects.desktop)
        XCTAssertEqual(envelope.notification.body, "Filtered")
    }

    func testHookCanFilterExistingPolicyEnvelope() async throws {
        var effects = TerminalNotificationPolicyEffects()
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.sound = false
        effects.command = false
        effects.paneFlash = false
        let envelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: "feed-session",
                surfaceId: nil,
                title: "Permission",
                subtitle: "",
                body: "Decision needed"
            ),
            context: TerminalNotificationPolicyContext(
                cwd: FileManager.default.temporaryDirectory.path,
                configPath: nil,
                hookId: nil,
                appFocused: false,
                focusedPanel: false
            ),
            effects: effects
        )
        let hook = CmuxResolvedNotificationHook(
            id: "feed-filter",
            command: #"sed 's/"desktop":true/"desktop":false/; s/"title":"Permission"/"title":"Filtered"/'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await TerminalNotificationPolicyEngine.evaluate(envelope: envelope, hooks: [hook])
        let filtered = try result.get()
        XCTAssertFalse(filtered.effects.desktop)
        XCTAssertEqual(filtered.notification.title, "Filtered")
        XCTAssertEqual(filtered.notification.workspaceId, "feed-session")
    }

    func testHookCanReturnPartialEffectsEnvelope() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Title",
            subtitle: "Subtitle",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "partial",
            command: #"printf '{"effects":{"desktop":false},"stop":true}'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        let envelope = try result.get()
        XCTAssertEqual(envelope.notification.title, "Title")
        XCTAssertEqual(envelope.notification.body, "Body")
        XCTAssertFalse(envelope.effects.desktop)
        XCTAssertTrue(envelope.effects.sound)
        XCTAssertTrue(envelope.effects.command)
        XCTAssertEqual(envelope.stop, true)
    }

    func testPartialEffectsPatchPreservesOmittedExistingFlags() async throws {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = false
        effects.command = false
        let envelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: UUID().uuidString,
                surfaceId: nil,
                title: "Title",
                subtitle: "Subtitle",
                body: "Body"
            ),
            context: TerminalNotificationPolicyContext(
                cwd: FileManager.default.temporaryDirectory.path,
                configPath: nil,
                hookId: nil,
                appFocused: false,
                focusedPanel: false
            ),
            effects: effects
        )
        let hook = CmuxResolvedNotificationHook(
            id: "partial",
            command: #"printf '{"effects":{"desktop":false}}'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await TerminalNotificationPolicyEngine.evaluate(envelope: envelope, hooks: [hook])
        let patched = try result.get()
        XCTAssertFalse(patched.effects.desktop)
        XCTAssertFalse(patched.effects.sound)
        XCTAssertFalse(patched.effects.command)
        XCTAssertTrue(patched.effects.record)
    }

    func testPartialNotificationPatchPreservesOmittedPayloadFields() async throws {
        let envelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: "workspace-1",
                surfaceId: "surface-1",
                title: "Title",
                subtitle: "Subtitle",
                body: "Body"
            ),
            context: TerminalNotificationPolicyContext(
                cwd: "/tmp/original",
                configPath: nil,
                hookId: nil,
                appFocused: false,
                focusedPanel: false
            )
        )
        let hook = CmuxResolvedNotificationHook(
            id: "partial-notification",
            command: #"printf '{"notification":{"title":"Retitled"},"context":{"appFocused":true}}'"#,
            timeoutSeconds: 5,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await TerminalNotificationPolicyEngine.evaluate(envelope: envelope, hooks: [hook])
        let patched = try result.get()
        XCTAssertEqual(patched.notification.workspaceId, "workspace-1")
        XCTAssertEqual(patched.notification.surfaceId, "surface-1")
        XCTAssertEqual(patched.notification.title, "Retitled")
        XCTAssertEqual(patched.notification.subtitle, "Subtitle")
        XCTAssertEqual(patched.notification.body, "Body")
        XCTAssertEqual(patched.context.configPath, "/tmp/cmux.json")
        XCTAssertEqual(patched.context.hookId, "partial-notification")
        XCTAssertTrue(patched.context.appFocused)
        XCTAssertFalse(patched.context.focusedPanel)
    }

    func testHookFailureReturnsFailureForDefaultFallback() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Title",
            subtitle: "",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "bad",
            command: "printf nope",
            timeoutSeconds: 5,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        switch result {
        case .success:
            XCTFail("Expected invalid JSON to fail")
        case .failure(let failure):
            XCTAssertEqual(failure.hookId, "bad")
            XCTAssertTrue(failure.message.contains("invalid JSON"))
        }
    }

    func testHookTimeoutReturnsFailureForDefaultFallback() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Title",
            subtitle: "",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "slow",
            command: "sleep 2; cat",
            timeoutSeconds: 0.1,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        switch result {
        case .success:
            XCTFail("Expected timeout to fail")
        case .failure(let failure):
            XCTAssertEqual(failure.hookId, "slow")
            XCTAssertTrue(failure.message.contains("timed out"))
        }
    }

    func testHookWithBackgroundChildInheritingStdoutDoesNotStall() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Title",
            subtitle: "",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "background-stdout",
            command: "sleep 3 & cat",
            timeoutSeconds: 5,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        // A background child inheriting the hook's stdout must not keep the
        // pipe open and stall `evaluate`. Assert the causal outcome — that the
        // hook completes and returns the unmodified envelope — rather than
        // timing the call. The completion is raced against a generous deadline
        // so a genuine stall fails the test instead of hanging it forever.
        let completed = expectation(description: "policy hook completes without stalling on inherited stdout")
        let resultBox = NotificationHookEvaluationResultBox()
        let evaluationTask = Task {
            let result = await evaluate(request: request, hooks: [hook])
            resultBox.store(result)
            completed.fulfill()
            return result
        }
        await fulfillment(of: [completed], timeout: 10.0)
        guard let result = resultBox.take() else {
            // The hook is still stalled on the inherited stdout pipe. Fail fast
            // instead of awaiting evaluationTask.value, which would hang until the
            // whole-suite timeout since the stalled call may ignore cancellation.
            evaluationTask.cancel()
            XCTFail("policy hook did not complete within 10s (stalled on inherited stdout)")
            return
        }
        let envelope = try result.get()
        XCTAssertEqual(envelope.notification.body, "Body")
    }
}

@MainActor
final class AppIconSettingsTests: XCTestCase {
    func testApplyDarkSetsRuntimeIconAndNotifiesDockTilePlugin() {
        let expectedIcon = NSImage(size: NSSize(width: 16, height: 16))
        var receivedRuntimeIcon: NSImage?
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { mode in
                XCTAssertEqual(mode, .dark)
                return expectedIcon
            },
            setApplicationIconImage: { icon in
                receivedRuntimeIcon = icon
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.dark, environment: environment)

        XCTAssertTrue(receivedRuntimeIcon === expectedIcon)
        XCTAssertEqual(dockTileNotificationCount, 1)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 1)
    }

    func testApplyAutomaticStartsObservationAndNotifiesDockTilePlugin() {
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { mode in
                XCTFail("Automatic mode should not request a manual icon image: \(mode.rawValue)")
                return nil
            },
            setApplicationIconImage: { _ in
                XCTFail("Automatic mode should delegate live updates to the appearance observer")
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.automatic, environment: environment)

        XCTAssertEqual(dockTileNotificationCount, 1)
        XCTAssertEqual(startObservationCallCount, 1)
        XCTAssertEqual(stopObservationCallCount, 0)
    }

    func testApplyDarkBeforeLaunchDoesNotTouchRuntimeIconState() {
        var imageRequestCount = 0
        var runtimeIconSetCount = 0
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { false },
            imageForMode: { _ in
                imageRequestCount += 1
                return NSImage(size: NSSize(width: 16, height: 16))
            },
            setApplicationIconImage: { _ in
                runtimeIconSetCount += 1
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.dark, environment: environment)

        XCTAssertEqual(imageRequestCount, 0)
        XCTAssertEqual(runtimeIconSetCount, 0)
        XCTAssertEqual(dockTileNotificationCount, 0)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 0)
    }
}

final class GhosttyCrashBreadcrumbTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var crashDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "GhosttyCrashBreadcrumbTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        crashDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-crash-breadcrumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: crashDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let crashDirectoryURL {
            try? FileManager.default.removeItem(at: crashDirectoryURL)
        }
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        crashDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testPendingCrashDetectedWhenNewerThanCleanExit() throws {
        let cleanExit = Date(timeIntervalSince1970: 100)
        let crashDate = Date(timeIntervalSince1970: 200)
        defaults.set(cleanExit, forKey: GhosttyCrashBreadcrumb.lastCleanExitDefaultsKey)
        let crashURL = try writeCrashFile(named: "newer.ghosttycrash", modifiedAt: crashDate)

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), crashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, crashDate)
    }

    func testPendingCrashDetectedFromMatchingEnvelopeWhenNewerThanCleanExit() throws {
        let cleanExit = Date(timeIntervalSince1970: 100)
        let crashDate = Date(timeIntervalSince1970: 200)
        defaults.set(cleanExit, forKey: GhosttyCrashBreadcrumb.lastCleanExitDefaultsKey)
        let currentExecutablePath = try XCTUnwrap(Bundle.main.executableURL?.path)
        let crashURL = try writeCrashEnvelope(
            named: "matching-newer.ghosttycrash",
            executablePath: currentExecutablePath,
            modifiedAt: crashDate
        )

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), crashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, crashDate)
    }

    func testPendingCrashIgnoresNewerCrashFromDifferentExecutable() throws {
        let currentCrashDate = Date(timeIntervalSince1970: 200)
        let foreignCrashDate = Date(timeIntervalSince1970: 300)
        let currentExecutablePath = try XCTUnwrap(Bundle.main.executableURL?.path)
        let currentCrashURL = try writeCrashEnvelope(
            named: "current.ghosttycrash",
            executablePath: currentExecutablePath,
            modifiedAt: currentCrashDate
        )
        _ = try writeCrashEnvelope(
            named: "foreign.ghosttycrash",
            executablePath: "/private/tmp/cmux-tbinput-unit/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
            modifiedAt: foreignCrashDate
        )

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), currentCrashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, currentCrashDate)
    }

    func testPendingCrashIgnoresForeignCrashWhenEventIsNotFirstEnvelopeItem() throws {
        let currentCrashDate = Date(timeIntervalSince1970: 200)
        let foreignCrashDate = Date(timeIntervalSince1970: 300)
        let currentExecutablePath = try XCTUnwrap(Bundle.main.executableURL?.path)
        let currentCrashURL = try writeCrashEnvelope(
            named: "current-before-foreign-leading-item.ghosttycrash",
            executablePath: currentExecutablePath,
            modifiedAt: currentCrashDate
        )
        _ = try writeCrashEnvelope(
            named: "foreign-leading-item.ghosttycrash",
            executablePath: "/private/tmp/cmux-tbinput-unit/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
            modifiedAt: foreignCrashDate,
            leadingItems: [
                (type: "attachment", payload: Data(#"{"filename":"metadata.txt"}"#.utf8)),
            ]
        )

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), currentCrashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, currentCrashDate)
    }

    func testPendingCrashReturnsNilForOnlyDifferentExecutableCrash() throws {
        _ = try writeCrashEnvelope(
            named: "foreign-only.ghosttycrash",
            executablePath: "/private/tmp/cmux-tbinput-unit/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
            modifiedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertNil(GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        ))
    }

    func testDefaultCrashDirectoryUsesCmuxStatePath() throws {
        XCTAssertTrue(
            GhosttyCrashBreadcrumb.defaultCrashDirectoryURL.path.hasSuffix("/.local/state/cmux/crash"),
            GhosttyCrashBreadcrumb.defaultCrashDirectoryURL.path
        )
    }

    func testPendingCrashIsOneTimeAfterBeingShown() throws {
        let crashDate = Date(timeIntervalSince1970: 300)
        let crashURL = try writeCrashFile(named: "shown.ghosttycrash", modifiedAt: crashDate)
        let pending = try XCTUnwrap(GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        ))
        XCTAssertEqual(pending.fileURL.resolvingSymlinksInPath(), crashURL.resolvingSymlinksInPath())

        GhosttyCrashBreadcrumb.markShown(pending, defaults: defaults)

        XCTAssertNil(GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        ))
    }

    private func writeCrashFile(named name: String, modifiedAt: Date) throws -> URL {
        let url = crashDirectoryURL.appendingPathComponent(name)
        try Data("MDMP".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeCrashEnvelope(
        named name: String,
        executablePath: String,
        modifiedAt: Date,
        leadingItems: [(type: String, payload: Data)] = []
    ) throws -> URL {
        let url = crashDirectoryURL.appendingPathComponent(name)
        let event = [
            "debug_meta": [
                "images": [
                    [
                        "code_file": executablePath,
                    ],
                ],
            ],
        ]
        let eventData = try JSONSerialization.data(withJSONObject: event)
        let eventHeader = #"{"type":"event","length":\#(eventData.count)}"#
        var envelope = Data(#"{"event_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        envelope.append(0x0A)
        for item in leadingItems {
            let itemHeader = #"{"type":"\#(item.type)","length":\#(item.payload.count)}"#
            envelope.append(Data(itemHeader.utf8))
            envelope.append(0x0A)
            envelope.append(item.payload)
            envelope.append(0x0A)
        }
        envelope.append(Data(eventHeader.utf8))
        envelope.append(0x0A)
        envelope.append(eventData)
        envelope.append(0x0A)
        try envelope.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }
}

@MainActor
final class NotificationDockBadgeTests: XCTestCase {
    private final class NotificationSettingsAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertFirstButtonReturn

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            return nextResponse
        }
    }

    override func tearDown() {
        TerminalNotificationStore.shared.resetNotificationSettingsPromptHooksForTesting()
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        TerminalNotificationStore.shared.resetNotificationDeliveryHandlerForTesting()
        TerminalNotificationStore.shared.resetSuppressedNotificationFeedbackHandlerForTesting()
        super.tearDown()
    }

    func testNotificationClickActionRoundTripsAndIsStored() {
        let store = TerminalNotificationStore.shared
        let path = "/tmp/cmux-crash-\(UUID().uuidString).ghosttycrash"
        let action = TerminalNotificationClickAction.revealInFinder(path: path)
        let userInfo = Dictionary(uniqueKeysWithValues: action.userInfo.map { (AnyHashable($0.key), $0.value as Any) })
        var delivered: TerminalNotification?

        XCTAssertEqual(TerminalNotificationClickAction(userInfo: userInfo), action)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            delivered = notification
        }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
        }

        store.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Crash",
            subtitle: "Diagnostic",
            body: "Diagnostic file saved",
            clickAction: action
        )

        XCTAssertEqual(store.notifications.first?.clickAction, action)
        XCTAssertEqual(delivered?.clickAction, action)
    }

    func testNotificationClickActionDoesNotMarkReadWhenRevealTargetIsMissing() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalStore = appDelegate.notificationStore
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Crash",
            subtitle: "Diagnostic",
            body: "Diagnostic file saved",
            createdAt: Date(),
            isRead: false,
            clickAction: .revealInFinder(path: "/tmp/cmux-missing-\(UUID().uuidString)/missing.ghosttycrash")
        )

        store.replaceNotificationsForTesting([notification])
        appDelegate.notificationStore = store
        defer {
            appDelegate.notificationStore = originalStore
            store.replaceNotificationsForTesting([])
        }

        XCTAssertFalse(appDelegate.openTerminalNotification(notification))
        XCTAssertFalse(try XCTUnwrap(store.notifications.first).isRead)
    }

    func testJumpToLatestUnreadSkipsClickActionNotifications() {
        let clickActionNotification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Crash",
            subtitle: "Diagnostic",
            body: "Diagnostic file saved",
            createdAt: Date(),
            isRead: false,
            clickAction: .revealInFinder(path: "/tmp/cmux-crash.ghosttycrash")
        )
        let terminalNotification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Done",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        var readNotification = terminalNotification
        readNotification.isRead = true

        XCTAssertFalse(AppDelegate.shouldOpenFromJumpToLatestUnread(clickActionNotification))
        XCTAssertTrue(AppDelegate.shouldOpenFromJumpToLatestUnread(terminalNotification))
        XCTAssertFalse(AppDelegate.shouldOpenFromJumpToLatestUnread(readNotification))
        XCTAssertFalse(AppDelegate.shouldOpenFromJumpToLatestUnread(
            terminalNotification,
            excludingNotificationId: terminalNotification.id
        ))
    }

    func testDockBadgeLabelEnabledAndCounted() {
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 1, isEnabled: true), "1")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 42, isEnabled: true), "42")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 100, isEnabled: true), "99+")
    }

    func testDockBadgeLabelHiddenWhenDisabledOrZero() {
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true))
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 5, isEnabled: false))
    }

    func testDockBadgeLabelShowsRunTagEvenWithoutUnread() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true, runTag: "verify-tag"),
            "verify-tag"
        )
    }

    func testDockBadgeLabelCombinesRunTagAndUnreadCount() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 7, isEnabled: true, runTag: "verify"),
            "verify:7"
        )
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 120, isEnabled: true, runTag: "verify"),
            "verify:99+"
        )
    }

    func testNotificationBadgePreferenceDefaultsToEnabled() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertFalse(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationBadgeSettings.dockBadgeEnabledKey)
        XCTAssertTrue(NotificationBadgeSettings.isDockBadgeEnabled(defaults: defaults))
    }

    func testNotificationPaneFlashPreferenceDefaultsToEnabled() {
        let suiteName = "NotificationPaneFlashSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationPaneFlashSettings.isEnabled(defaults: defaults))

        defaults.set(false, forKey: NotificationPaneFlashSettings.enabledKey)
        XCTAssertFalse(NotificationPaneFlashSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: NotificationPaneFlashSettings.enabledKey)
        XCTAssertTrue(NotificationPaneFlashSettings.isEnabled(defaults: defaults))
    }

    func testMenuBarExtraPreferenceDefaultsToVisible() {
        let suiteName = "MenuBarExtraVisibilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults))

        defaults.set(false, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertFalse(MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults))

        defaults.set(true, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertTrue(MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults))
    }

    func testMenuBarOnlyPreferenceDefaultsToRegularActivationPolicy() {
        let suiteName = "MenuBarOnlySettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertFalse(MenuBarOnlySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(MenuBarOnlySettings.activationPolicy(defaults: defaults), .regular)
        XCTAssertFalse(MenuBarOnlySettings.shouldShowMainWindowMenuItem(defaults: defaults))

        defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        XCTAssertTrue(MenuBarOnlySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(MenuBarOnlySettings.activationPolicy(defaults: defaults), .accessory)
        XCTAssertTrue(MenuBarOnlySettings.shouldShowMainWindowMenuItem(defaults: defaults))

        defaults.set(false, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        XCTAssertFalse(MenuBarOnlySettings.isEnabled(defaults: defaults))
        XCTAssertEqual(MenuBarOnlySettings.activationPolicy(defaults: defaults), .regular)
        XCTAssertFalse(MenuBarOnlySettings.shouldShowMainWindowMenuItem(defaults: defaults))
    }

    func testMenuBarOnlyForcesMenuBarExtraVisible() {
        let suiteName = "MenuBarOnlyVisibilityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(false, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertFalse(MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults))

        defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        XCTAssertTrue(MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults))

        defaults.set(false, forKey: MenuBarOnlySettings.menuBarOnlyKey)
        defaults.set(true, forKey: MenuBarExtraSettings.showInMenuBarKey)
        XCTAssertTrue(MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults))
    }

    func testNotificationSoundUsesSystemSoundForDefaultAndNamedSounds() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationSoundSettings.usesSystemSound(defaults: defaults))

        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        XCTAssertTrue(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-notification-sound-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        XCTAssertNotNil(NotificationSoundSettings.sound(
            defaults: defaults,
            systemSoundStagingDirectory: stagingDirectory
        ))
        let stagedSoundURL = stagingDirectory.appendingPathComponent(
            NotificationSoundSettings.stagedSystemSoundFileName(for: "Ping"),
            isDirectory: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedSoundURL.path))
    }

    func testNotificationSoundDisablesSystemSoundForNoneAndCustomFile() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("none", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))
    }

    func testNotificationCustomFileURLExpandsTildePath() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let rawPath = "~/Library/Sounds/my-custom.wav"
        defaults.set(rawPath, forKey: NotificationSoundSettings.customFilePathKey)
        let expectedPath = (rawPath as NSString).expandingTildeInPath
        XCTAssertEqual(NotificationSoundSettings.customFileURL(defaults: defaults)?.path, expectedPath)
    }

    func testNotificationCustomFileSelectionMustBeExplicit() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("~/Library/Sounds/my-custom.wav", forKey: NotificationSoundSettings.customFilePathKey)

        defaults.set("none", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))

        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        XCTAssertTrue(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))
    }

    func testNotificationCustomStagingPreservesSourceFileWithCmuxPrefix() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let soundsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        do {
            try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create sounds directory: \(error)")
            return
        }

        let sourceURL = soundsDirectory.appendingPathComponent(
            "cmux-custom-notification-sound.source-\(UUID().uuidString).wav",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: sourceURL)
        }

        do {
            try Data("test".utf8).write(to: sourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write source custom sound file: \(error)")
            return
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(sourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        _ = NotificationSoundSettings.sound(defaults: defaults)

        guard let stagedName = NotificationSoundSettings.stagedCustomSoundName(defaults: defaults) else {
            XCTFail("Expected staged custom sound name")
            return
        }
        let stagedURL = soundsDirectory.appendingPathComponent(stagedName, isDirectory: false)
        defer {
            try? fileManager.removeItem(at: stagedURL)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(stagedName.hasPrefix("cmux-custom-notification-sound-"))
        XCTAssertTrue(stagedName.hasSuffix(".wav"))
    }

    func testNotificationCustomUnsupportedExtensionsStageAsCaf() {
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "mp3"),
            "caf"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "M4A"),
            "caf"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "wav"),
            "wav"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "AIFF"),
            "aiff"
        )

        let sourceA = URL(fileURLWithPath: "/tmp/custom-a.mp3")
        let sourceB = URL(fileURLWithPath: "/tmp/custom-b.mp3")
        let stagedA = NotificationSoundSettings.stagedCustomSoundFileName(
            forSourceURL: sourceA,
            destinationExtension: "caf"
        )
        let stagedB = NotificationSoundSettings.stagedCustomSoundFileName(
            forSourceURL: sourceB,
            destinationExtension: "caf"
        )
        XCTAssertNotEqual(stagedA, stagedB)
        XCTAssertTrue(stagedA.hasPrefix("cmux-custom-notification-sound-"))
        XCTAssertTrue(stagedA.hasSuffix(".caf"))
    }

    func testNotificationCustomPreparationKeepsActiveSourceMetadataSidecar() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let soundsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        do {
            try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create sounds directory: \(error)")
            return
        }

        let sourceURL = soundsDirectory.appendingPathComponent(
            "cmux-custom-notification-sound.metadata-\(UUID().uuidString).wav",
            isDirectory: false
        )
        do {
            try Data("test".utf8).write(to: sourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write source custom sound file: \(error)")
            return
        }
        defer {
            try? fileManager.removeItem(at: sourceURL)
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(sourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        let prepareResult = NotificationSoundSettings.prepareCustomFileForNotifications(path: sourceURL.path)
        let stagedName: String
        switch prepareResult {
        case .success(let name):
            stagedName = name
        case .failure(let issue):
            XCTFail("Expected custom sound preparation success, got \(issue)")
            return
        }

        let stagedURL = soundsDirectory.appendingPathComponent(stagedName, isDirectory: false)
        let metadataURL = stagedURL.appendingPathExtension("source-metadata")
        defer {
            try? fileManager.removeItem(at: stagedURL)
            try? fileManager.removeItem(at: metadataURL)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: metadataURL.path))
    }

    func testNotificationCustomSoundReturnsNilWhenPreparationFails() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let invalidSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-invalid-sound-\(UUID().uuidString).mp3", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: invalidSourceURL)
            let stagedURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("cmux-custom-notification-sound.caf", isDirectory: false)
            try? FileManager.default.removeItem(at: stagedURL)
        }

        do {
            try Data("not-audio".utf8).write(to: invalidSourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write invalid custom sound source: \(error)")
            return
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(invalidSourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))
    }

    func testNotificationCustomPreparationReportsMissingFile() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-missing-\(UUID().uuidString).wav", isDirectory: false)
            .path

        let result = NotificationSoundSettings.prepareCustomFileForNotifications(path: missingPath)
        switch result {
        case .success:
            XCTFail("Expected missing file failure")
        case .failure(let issue):
            guard case .missingFile = issue else {
                XCTFail("Expected missingFile issue, got \(issue)")
                return
            }
        }
    }

    func testFocusedTerminalNotificationStillRunsLocalSoundFeedbackWhenExternalDeliveryIsSuppressed() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("AppDelegate.shared must be set for this test")
            return
        }
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredNotificationIDs: [UUID] = []
        var localFeedbackNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotificationIDs.append(notification.id)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, notification in
            localFeedbackNotificationIDs.append(notification.id)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected selected workspace with a focused terminal panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )

        let createdNotificationID = try XCTUnwrap(store.notifications.first?.id)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertTrue(deliveredNotificationIDs.isEmpty)
        XCTAssertEqual(localFeedbackNotificationIDs.count, 1)
        XCTAssertEqual(localFeedbackNotificationIDs, [createdNotificationID])
    }

    func testFocusedTerminalSuppressedNotificationRunsCustomCommand() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("AppDelegate.shared must be set for this test")
            return
        }
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let commandOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-notification-command-\(UUID().uuidString).txt", isDirectory: false)

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let hadSoundValue = defaults.object(forKey: NotificationSoundSettings.key) != nil
        let originalSoundValue = defaults.object(forKey: NotificationSoundSettings.key)
        let hadCommandValue = defaults.object(forKey: NotificationSoundSettings.customCommandKey) != nil
        let originalCommandValue = defaults.object(forKey: NotificationSoundSettings.customCommandKey)

        var deliveredNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotificationIDs.append(notification.id)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set("none", forKey: NotificationSoundSettings.key)
        defaults.set(
            "printf '%s\\n%s\\n%s' \"$CMUX_NOTIFICATION_TITLE\" \"$CMUX_NOTIFICATION_SUBTITLE\" \"$CMUX_NOTIFICATION_BODY\" > '\(commandOutputURL.path)'",
            forKey: NotificationSoundSettings.customCommandKey
        )

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if hadSoundValue {
                defaults.set(originalSoundValue, forKey: NotificationSoundSettings.key)
            } else {
                defaults.removeObject(forKey: NotificationSoundSettings.key)
            }
            if hadCommandValue {
                defaults.set(originalCommandValue, forKey: NotificationSoundSettings.customCommandKey)
            } else {
                defaults.removeObject(forKey: NotificationSoundSettings.customCommandKey)
            }
            try? FileManager.default.removeItem(at: commandOutputURL)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected selected workspace with a focused terminal panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "",
            subtitle: "Focused subtitle",
            body: "Focused body"
        )

        let commandFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: commandOutputURL.path)
            },
            object: NSObject()
        )
        XCTAssertEqual(XCTWaiter().wait(for: [commandFinished], timeout: 10.0), .completed)
        XCTAssertTrue(deliveredNotificationIDs.isEmpty)

        let output = try String(contentsOf: commandOutputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedTitle = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        XCTAssertEqual(output.components(separatedBy: "\n"), [expectedTitle, "Focused subtitle", "Focused body"])
    }

    func testNotificationAuthorizationStateMappingCoversKnownUNAuthorizationStatuses() {
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .notDetermined), .notDetermined)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .denied), .denied)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .authorized), .authorized)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .provisional), .provisional)
    }

    func testNotificationAuthorizationStateDeliveryCapability() {
        XCTAssertFalse(NotificationAuthorizationState.unknown.allowsDelivery)
        XCTAssertFalse(NotificationAuthorizationState.notDetermined.allowsDelivery)
        XCTAssertFalse(NotificationAuthorizationState.denied.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.authorized.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.provisional.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.ephemeral.allowsDelivery)
    }

    func testNotificationDeliveryAuthorizationUsesCachedTerminalStates() {
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .unknown, isAppActive: false))
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .notDetermined, isAppActive: true))
        XCTAssertEqual(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .notDetermined, isAppActive: false), false)
        XCTAssertEqual(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .denied, isAppActive: false), false)
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .authorized, isAppActive: false))
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .provisional, isAppActive: false))
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .ephemeral, isAppActive: false))
    }

    func testNotificationAuthorizationDefersFirstPromptWhileAppIsInactive() {
        XCTAssertTrue(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: false
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: true
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .authorized,
                isAppActive: false
            )
        )
    }

    func testNotificationAuthorizationRequestGatingAllowsSettingsRetry() {
        XCTAssertTrue(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: false,
                hasRequestedAutomaticAuthorization: true
            )
        )
        XCTAssertTrue(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: true,
                hasRequestedAutomaticAuthorization: false
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: true,
                hasRequestedAutomaticAuthorization: true
            )
        )
    }

    func testNotificationSettingsPromptUsesSheetAndNeverRunsModal() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var openedURL: URL?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { window },
            alertFactory: { alertSpy },
            scheduler: { _, block in block() },
            urlOpener: { openedURL = $0 }
        )
        addTeardownBlock {
            store.resetNotificationSettingsPromptHooksForTesting()
        }

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        guard let encodedBundleIdentifier = Bundle.main.bundleIdentifier?
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            XCTFail("Expected test bundle identifier to be URL-encodable")
            return
        }
        XCTAssertEqual(
            openedURL?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encodedBundleIdentifier)"
        )
    }

    func testNotificationSettingsPromptRetriesUntilWindowExists() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        alertSpy.nextResponse = .alertSecondButtonReturn

        var queuedRetryBlocks: [() -> Void] = []
        var promptWindow: NSWindow?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { promptWindow },
            alertFactory: { alertSpy },
            scheduler: { _, block in queuedRetryBlocks.append(block) },
            urlOpener: { _ in
                XCTFail("Should not open settings for Not Now response")
            }
        )
        addTeardownBlock {
            store.resetNotificationSettingsPromptHooksForTesting()
        }

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        XCTAssertEqual(queuedRetryBlocks.count, 1)

        promptWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        queuedRetryBlocks.removeFirst()()

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }

    func testNotificationIndexesTrackUnreadCountsByTabAndSurface() {
        let tabA = UUID()
        let tabB = UUID()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let notificationAUnread = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: surfaceA,
            title: "A unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        let notificationARead = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: surfaceB,
            title: "A read",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )
        let notificationBUnread = TerminalNotification(
            id: UUID(),
            tabId: tabB,
            surfaceId: nil,
            title: "B unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([
            notificationAUnread,
            notificationARead,
            notificationBUnread
        ])

        XCTAssertEqual(store.unreadCount, 2)
        XCTAssertEqual(store.unreadCount(forTabId: tabA), 1)
        XCTAssertEqual(store.unreadCount(forTabId: tabB), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tabA, surfaceId: surfaceA))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: tabA, surfaceId: surfaceB))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tabB, surfaceId: nil))
        XCTAssertEqual(store.latestNotification(forTabId: tabA)?.id, notificationAUnread.id)
        XCTAssertEqual(store.latestNotification(forTabId: tabB)?.id, notificationBUnread.id)
    }

    func testNotificationIndexesUpdateAfterReadAndClearMutations() {
        let tab = UUID()
        let surfaceUnread = UUID()
        let surfaceRead = UUID()
        let unreadNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surfaceUnread,
            title: "Unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        let readNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surfaceRead,
            title: "Read",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([unreadNotification, readNotification])
        XCTAssertEqual(store.unreadCount(forTabId: tab), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tab, surfaceId: surfaceUnread))

        store.markRead(forTabId: tab, surfaceId: surfaceUnread)
        XCTAssertEqual(store.unreadCount(forTabId: tab), 0)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: tab, surfaceId: surfaceUnread))
        XCTAssertEqual(store.latestNotification(forTabId: tab)?.id, unreadNotification.id)

        store.clearNotifications(forTabId: tab)
        XCTAssertEqual(store.unreadCount(forTabId: tab), 0)
        XCTAssertNil(store.latestNotification(forTabId: tab))
    }

    func testClearLatestNotificationRemovesOnlyCurrentSidebarPreviewSource() {
        let tab = UUID()
        let latestSurface = UUID()
        let previousSurface = UUID()
        let latestNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: latestSurface,
            title: "Latest",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )
        let previousNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: previousSurface,
            title: "Previous",
            subtitle: "",
            body: "",
            createdAt: Date().addingTimeInterval(-1),
            isRead: true
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([latestNotification, previousNotification])
        XCTAssertEqual(store.latestNotification(forTabId: tab)?.id, latestNotification.id)

        store.clearLatestNotification(forTabId: tab)
        XCTAssertEqual(store.latestNotification(forTabId: tab)?.id, previousNotification.id)
    }

    func testWorkspaceNotificationMenuProjectionFiltersAndSortsNewestFirst() {
        let tabA = UUID()
        let tabB = UUID()
        let unrelatedTab = UUID()
        let older = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: nil,
            title: "Older",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 100),
            isRead: true
        )
        let latest = TerminalNotification(
            id: UUID(),
            tabId: tabB,
            surfaceId: nil,
            title: "Latest",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 300),
            isRead: false
        )
        let middle = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: nil,
            title: "Middle",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 200),
            isRead: false
        )
        let unrelated = TerminalNotification(
            id: UUID(),
            tabId: unrelatedTab,
            surfaceId: nil,
            title: "Unrelated",
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 400),
            isRead: false
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([older, unrelated, latest, middle])

        XCTAssertEqual(
            store.notifications(forTabIds: [tabA, tabB]).map(\.id),
            [latest.id, middle.id, older.id]
        )
    }
}


final class MenuBarBadgeLabelFormatterTests: XCTestCase {
    func testBadgeLabelFormatting() {
        XCTAssertNil(MenuBarBadgeLabelFormatter.badgeText(for: 0))
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 1), "1")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 9), "9")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 10), "9+")
        XCTAssertEqual(MenuBarBadgeLabelFormatter.badgeText(for: 47), "9+")
    }
}

@MainActor
final class FocusedNotificationIndicatorTests: XCTestCase {
    func testFocusedNotificationIndicatorRemainsVisibleAfterFocusedNotificationIsRead() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Focused",
            subtitle: "",
            body: ""
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        store.markRead(forTabId: workspace.id, surfaceId: panelId)

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        store.clearFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
    }

    func testNewNotificationOnDifferentSurfaceClearsPreviousFocusedReadIndicator() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let leftPanelId = workspace.focusedPanelId,
              let rightPanel = workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
            XCTFail("Expected split workspace setup")
            return
        }

        workspace.focusPanel(rightPanel.id)

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: rightPanel.id)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: leftPanelId,
            title: "Left",
            subtitle: "",
            body: ""
        )

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: rightPanel.id))
    }
}


final class NotificationMenuSnapshotBuilderTests: XCTestCase {
    func testSnapshotCountsUnreadAndLimitsRecentItems() {
        let notifications = (0..<8).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "N\(index)",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: index.isMultiple(of: 2)
            )
        }

        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notifications,
            maxInlineNotificationItems: 3
        )

        XCTAssertEqual(snapshot.unreadCount, 4)
        XCTAssertTrue(snapshot.hasNotifications)
        XCTAssertTrue(snapshot.hasUnreadNotifications)
        XCTAssertEqual(snapshot.recentNotifications.count, 3)
        XCTAssertEqual(snapshot.recentNotifications.map(\.id), Array(notifications.prefix(3)).map(\.id))
    }

    func testSnapshotCountsWorkspaceUnreadIndicatorsWithoutNotificationRecords() {
        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: [],
            workspaceUnreadIndicatorCount: 2
        )

        XCTAssertEqual(snapshot.unreadCount, 2)
        XCTAssertTrue(snapshot.hasNotifications)
        XCTAssertTrue(snapshot.hasUnreadNotifications)
        XCTAssertTrue(snapshot.recentNotifications.isEmpty)
    }

    func testStateHintTitleHandlesSingularPluralAndZero() {
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 0), "No unread notifications")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 1), "1 unread notification")
        XCTAssertEqual(NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: 2), "2 unread notifications")
    }
}


final class MenuBarBuildHintFormatterTests: XCTestCase {
    func testReleaseBuildShowsNoHint() {
        XCTAssertNil(MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: false))
    }

    func testDebugBuildWithTagShowsTag() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV menubar-extra", isDebugBuild: true),
            "Build Tag: menubar-extra"
        )
    }

    func testDebugBuildWithoutTagShowsUntagged() {
        XCTAssertEqual(
            MenuBarBuildHintFormatter.menuTitle(appName: "cmux DEV", isDebugBuild: true),
            "Build: DEV (untagged)"
        )
    }
}


final class MenuBarNotificationLineFormatterTests: XCTestCase {
    func testPlainTitleContainsUnreadDotBodyAndTab() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Build finished",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: "workspace-1")
        XCTAssertTrue(line.hasPrefix("● Build finished"))
        XCTAssertTrue(line.contains("All checks passed"))
        XCTAssertTrue(line.contains("workspace-1"))
    }

    func testPlainTitleFallsBackToSubtitleWhenBodyEmpty() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Deploy",
            subtitle: "staging",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: true
        )

        let line = MenuBarNotificationLineFormatter.plainTitle(notification: notification, tabTitle: nil)
        XCTAssertTrue(line.hasPrefix("  Deploy"))
        XCTAssertTrue(line.contains("staging"))
    }

    func testMenuTitleWrapsAndTruncatesToThreeLines() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Extremely long notification title for wrapping behavior validation",
            subtitle: "",
            body: Array(repeating: "this body should wrap and eventually truncate", count: 8).joined(separator: " "),
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "workspace-with-a-very-long-name",
            maxWidth: 120,
            maxLines: 3
        )

        XCTAssertLessThanOrEqual(title.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testMenuTitlePreservesShortTextWithoutEllipsis() {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Done",
            subtitle: "",
            body: "All checks passed",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false
        )

        let title = MenuBarNotificationLineFormatter.menuTitle(
            notification: notification,
            tabTitle: "w1",
            maxWidth: 320,
            maxLines: 3
        )

        XCTAssertFalse(title.hasSuffix("…"))
    }
}


final class MenuBarIconDebugSettingsTests: XCTestCase {
    func testDisplayedUnreadCountUsesPreviewOverrideWhenEnabled() {
        let suiteName = "MenuBarIconDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MenuBarIconDebugSettings.previewEnabledKey)
        defaults.set(7, forKey: MenuBarIconDebugSettings.previewCountKey)

        XCTAssertEqual(MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: 2, defaults: defaults), 7)
    }

    func testBadgeRenderConfigClampsInvalidValues() {
        let suiteName = "MenuBarIconDebugSettingsTests.Clamp.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-100, forKey: MenuBarIconDebugSettings.badgeRectXKey)
        defaults.set(200, forKey: MenuBarIconDebugSettings.badgeRectYKey)
        defaults.set(-100, forKey: MenuBarIconDebugSettings.singleDigitFontSizeKey)
        defaults.set(100, forKey: MenuBarIconDebugSettings.multiDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.badgeRect.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(config.badgeRect.origin.y, 20, accuracy: 0.001)
        XCTAssertEqual(config.singleDigitFontSize, 6, accuracy: 0.001)
        XCTAssertEqual(config.multiDigitXAdjust, 4, accuracy: 0.001)
    }

    func testBadgeRenderConfigUsesLegacySingleDigitXAdjustWhenNewKeyMissing() {
        let suiteName = "MenuBarIconDebugSettingsTests.LegacyX.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2.5, forKey: MenuBarIconDebugSettings.legacySingleDigitXAdjustKey)

        let config = MenuBarIconDebugSettings.badgeRenderConfig(defaults: defaults)
        XCTAssertEqual(config.singleDigitXAdjust, 2.5, accuracy: 0.001)
    }
}

@MainActor


final class MenuBarIconRendererTests: XCTestCase {
    func testImageWidthDoesNotShiftWhenBadgeAppears() {
        let noBadge = MenuBarIconRenderer.makeImage(unreadCount: 0)
        let withBadge = MenuBarIconRenderer.makeImage(unreadCount: 2)

        XCTAssertEqual(noBadge.size.width, 18, accuracy: 0.001)
        XCTAssertEqual(withBadge.size.width, 18, accuracy: 0.001)
    }
}
