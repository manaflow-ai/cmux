import AppKit
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// SAFETY: every mutable field is accessed only while `lock` is held.
private final class TitleScheduleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduledAction: (@Sendable () async -> Void)?
    private var recordedScheduleCount = 0

    var scheduleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedScheduleCount
    }

    func schedule(
        _ interval: Duration,
        action: @escaping @Sendable () async -> Void
    ) -> GhosttyTitleUpdateDispatcher.Cancellation {
        _ = interval
        lock.lock()
        recordedScheduleCount += 1
        scheduledAction = action
        lock.unlock()
        return { [weak self] in self?.cancel() }
    }

    func fire() async {
        let action = takeScheduledAction()
        await action?()
    }

    private func takeScheduledAction() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let action = scheduledAction
        scheduledAction = nil
        return action
    }

    private func cancel() {
        lock.lock()
        scheduledAction = nil
        lock.unlock()
    }
}

@Suite("Notification policy in-flight ordering")
@MainActor
struct TerminalNotificationPolicyInFlightStoreTests {
    @Test func completedRequestsApplyInRegistrationOrder() {
        let store = TerminalNotificationPolicyInFlightStore()
        var applied: [String] = []
        let tabId = UUID()
        let surfaceId = UUID()
        let first = store.register(
            makeRequest(tabId: tabId, surfaceId: surfaceId, title: "first"),
            generation: 1,
            onDiscard: {}
        )
        let second = store.register(
            makeRequest(tabId: tabId, surfaceId: surfaceId, title: "second"),
            generation: 1,
            onDiscard: {}
        )

        store.complete(second) { applied.append("second") }
        #expect(applied.isEmpty)
        store.complete(first) { applied.append("first") }

        #expect(applied == ["first", "second"])
    }

    @Test func blockedDeliveryIdentityDoesNotDelayAnotherWorkspace() {
        let store = TerminalNotificationPolicyInFlightStore()
        var applied: [String] = []
        _ = store.register(
            makeRequest(tabId: UUID(), surfaceId: nil, title: "blocked"),
            generation: 1,
            onDiscard: {}
        )
        let independent = store.register(
            makeRequest(tabId: UUID(), surfaceId: nil, title: "independent"),
            generation: 1,
            onDiscard: {}
        )

        store.complete(independent) { applied.append("independent") }

        #expect(applied == ["independent"])
    }

    @Test func rebindMovesPendingIndexesToDestinationWorkspace() {
        let store = TerminalNotificationPolicyInFlightStore()
        let sourceTabId = UUID()
        let destinationTabId = UUID()
        let surfaceId = UUID()
        _ = store.register(
            makeRequest(
                tabId: sourceTabId,
                surfaceId: surfaceId,
                retargetsToLiveSurfaceOwner: true,
                title: "moving"
            ),
            generation: 1,
            onDiscard: {}
        )

        store.rebindSurface(
            fromTabId: sourceTabId,
            toTabId: destinationTabId,
            surfaceId: surfaceId
        )

        #expect(!store.hasPendingRequest(forTabId: sourceTabId))
        #expect(store.hasPendingRequest(forTabId: destinationTabId))
        #expect(store.hasPendingRequest(forTabId: destinationTabId, surfaceId: surfaceId))
    }

    @Test func panelAliasDiscardCancelsPendingRequest() {
        let store = TerminalNotificationPolicyInFlightStore()
        let tabId = UUID()
        let surfaceId = UUID()
        let panelId = UUID()
        var wasDiscarded = false
        _ = store.register(
            makeRequest(tabId: tabId, surfaceId: surfaceId, panelId: panelId, title: "pending"),
            generation: 1,
            onDiscard: { wasDiscarded = true }
        )

        store.discard(forTabId: tabId, surfaceId: panelId)

        #expect(wasDiscarded)
        #expect(!store.hasPendingRequest(forTabId: tabId))
        #expect(!store.hasPendingRequest(forTabId: tabId, surfaceId: surfaceId))
        #expect(!store.hasPendingRequest(forTabId: tabId, surfaceId: panelId))
    }

    @Test func pendingIndexesCoverSurfaceAndPanelAliases() {
        let store = TerminalNotificationPolicyInFlightStore()
        let tabId = UUID()
        let surfaceId = UUID()
        let panelId = UUID()
        let id = store.register(
            makeRequest(tabId: tabId, surfaceId: surfaceId, panelId: panelId, title: "pending"),
            generation: 1,
            onDiscard: {}
        )

        #expect(store.hasPendingRequest(forTabId: tabId))
        #expect(store.hasPendingRequest(forTabId: tabId, surfaceId: surfaceId))
        #expect(store.hasPendingRequest(forTabId: tabId, surfaceId: panelId))
        #expect(store.claim(id))
        #expect(!store.hasPendingRequest(forTabId: tabId))
    }

    private func makeRequest(
        tabId: UUID = UUID(),
        surfaceId: UUID? = UUID(),
        panelId: UUID? = nil,
        retargetsToLiveSurfaceOwner: Bool = false,
        title: String
    ) -> TerminalNotificationPolicyRequest {
        TerminalNotificationPolicyRequest(
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner,
            title: title,
            subtitle: "",
            body: "",
            cwd: nil,
            isAppFocused: false,
            isFocusedPanel: false
        )
    }
}

@Suite("Synchronous generic notification delivery", .serialized)
@MainActor
struct SynchronousGenericNotificationDeliveryTests {
    @Test func noHookNotificationIsImmediatelyObservable() {
        let store = TerminalNotificationStore.shared
        let tabId = UUID()
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
        }

        store.addNotification(
            tabId: tabId,
            surfaceId: nil,
            title: "Immediate",
            subtitle: "",
            body: "Visible before return",
            retargetsToLiveSurfaceOwner: false,
            resolvedHooks: []
        )

        #expect(store.notifications.map(\.tabId) == [tabId])
        #expect(store.notifications.map(\.title) == ["Immediate"])
    }
}

@Suite("Ghostty title update dispatcher")
@MainActor
struct GhosttyTitleUpdateDispatcherTests {
    @Test func burstPublishesOnlyLatestTitle() async {
        var published: [GhosttyTitleUpdate] = []
        let scheduler = TitleScheduleRecorder()
        let dispatcher = GhosttyTitleUpdateDispatcher(schedule: { interval, action in
            scheduler.schedule(interval, action: action)
        }) { updates in
            published.append(contentsOf: updates)
        }
        let tabId = UUID()
        let surfaceId = UUID()
        let source = NSObject()
        let sourceIdentifier = ObjectIdentifier(source)

        for sequence in 1...600 {
            await dispatcher.receive(GhosttyTitleUpdate(
                tabId: tabId,
                surfaceId: surfaceId,
                title: "spinner-\(sequence)",
                sourceSurfaceIdentifier: sourceIdentifier
            ))
        }
        #expect(scheduler.scheduleCount == 1)
        await scheduler.fire()

        #expect(published.count == 1)
        #expect(published.first?.title == "spinner-600")
    }

    @Test func duplicatePublishedTitleDoesNotPublishAgain() async {
        var published: [GhosttyTitleUpdate] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(schedule: { _, _ in
            {}
        }) { updates in
            published.append(contentsOf: updates)
        }
        let source = NSObject()
        let sourceIdentifier = ObjectIdentifier(source)
        let first = GhosttyTitleUpdate(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "unchanged",
            sourceSurfaceIdentifier: sourceIdentifier
        )

        await dispatcher.receive(first)
        await dispatcher.flushNow()
        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: first.tabId,
            surfaceId: first.surfaceId,
            title: first.title,
            sourceSurfaceIdentifier: sourceIdentifier
        ))
        await dispatcher.flushNow()

        #expect(published.map(\.title) == ["unchanged"])
    }

    @Test func retirementDropsPendingTitle() async {
        var published: [GhosttyTitleUpdate] = []
        let attachmentGeneration = AtomicUInt64Generation()
        let dispatcher = GhosttyTitleUpdateDispatcher(
            attachmentGeneration: attachmentGeneration,
            schedule: { _, _ in {} }
        ) { updates in
            published.append(contentsOf: updates)
        }
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())

        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: UUID(),
            surfaceId: surfaceId,
            title: "pending",
            sourceSurfaceIdentifier: sourceIdentifier
        ))
        await dispatcher.retireUpdates(before: attachmentGeneration.advanceRelaxed())
        await dispatcher.flushNow()

        #expect(published.isEmpty)
    }

    @Test func newGenerationSurvivesLateRetirementCleanup() async {
        var published: [GhosttyTitleUpdate] = []
        let attachmentGeneration = AtomicUInt64Generation()
        let dispatcher = GhosttyTitleUpdateDispatcher(
            attachmentGeneration: attachmentGeneration,
            schedule: { _, _ in {} }
        ) { updates in
            published.append(contentsOf: updates)
        }
        let generation = attachmentGeneration.advanceRelaxed()
        let update = GhosttyTitleUpdate(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "reattached",
            sourceSurfaceIdentifier: ObjectIdentifier(NSObject()),
            attachmentGeneration: generation
        )

        await dispatcher.receive(update)
        await dispatcher.retireUpdates(before: generation)
        await dispatcher.flushNow()

        #expect(published == [update])
    }

    @Test func workspaceMoveKeepsOneSurfaceLifetimeAndLatestRoute() async {
        var published: [GhosttyTitleUpdate] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(schedule: { _, _ in
            {}
        }) { updates in
            published.append(contentsOf: updates)
        }
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())
        let destinationTabId = UUID()
        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: UUID(), surfaceId: surfaceId, title: "stable",
            sourceSurfaceIdentifier: sourceIdentifier
        ))
        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: destinationTabId, surfaceId: surfaceId, title: "stable",
            sourceSurfaceIdentifier: sourceIdentifier
        ))
        await dispatcher.flushNow()

        #expect(published.count == 1)
        #expect(published.first?.tabId == destinationTabId)
        #expect(published.first?.title == "stable")
    }
}

@Suite("Ghostty title update ingress")
@MainActor
struct GhosttyTitleUpdateIngressTests {
    @Test func duplicateCallbackTitleIsRejectedBeforeEnqueue() {
        let ingress = GhosttyTitleUpdateIngress()
        let tabId = UUID()
        let surfaceId = UUID()
        let source = NSObject()

        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurface: source,
            title: "stable"
        ))
        #expect(!ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurface: source,
            title: "stable"
        ))
        #expect(ingress.submit(
            tabId: UUID(),
            surfaceId: surfaceId,
            sourceSurface: source,
            title: "stable"
        ))
    }

    @Test func retiringAttachmentAllowsItsFirstRepeatedTitleAfterReattach() {
        let ingress = GhosttyTitleUpdateIngress()
        let tabId = UUID()
        let surfaceId = UUID()
        let source = NSObject()

        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurface: source,
            title: "stable"
        ))
        ingress.retireCurrentAttachment()
        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurface: source,
            title: "stable"
        ))
    }
}

@Suite("Right-sidebar mode shortcut matcher")
@MainActor
struct RightSidebarModeShortcutMatcherTests {
    @Test func ordinaryTypingUsesCachedModifierBucketWithoutLookupOrLayoutWork() {
        var shortcutLookupCount = 0
        var layoutLookupCount = 0
        let matcher = RightSidebarModeShortcutMatcher(
            shortcutProvider: { _ in
                shortcutLookupCount += 1
                return StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
            },
            availability: { _ in true },
            layoutCharacterProvider: { _, _ in
                layoutLookupCount += 1
                return "b"
            }
        )
        let event = makeKeyEvent(characters: "a", modifiers: [])
        let initialLookupCount = shortcutLookupCount

        for _ in 0..<100 {
            #expect(matcher.modeShortcut(for: event, allowingAction: { _ in true }) == nil)
        }

        #expect(initialLookupCount == 5)
        #expect(shortcutLookupCount == initialLookupCount)
        #expect(layoutLookupCount == 0)
    }

    @Test func reloadRebuildsShortcutSnapshotOnce() {
        var shortcutLookupCount = 0
        let matcher = RightSidebarModeShortcutMatcher(
            shortcutProvider: { _ in
                shortcutLookupCount += 1
                return StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
            },
            availability: { _ in true },
            layoutCharacterProvider: { _, _ in nil }
        )

        #expect(shortcutLookupCount == 5)
        matcher.reload()
        #expect(shortcutLookupCount == 10)
        _ = matcher.modeShortcut(for: makeKeyEvent(characters: "x", modifiers: []), allowingAction: { _ in true })
        #expect(shortcutLookupCount == 10)
    }

    private func makeKeyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }
}
