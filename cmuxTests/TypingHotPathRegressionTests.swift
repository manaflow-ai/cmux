import AppKit
import XCTest
@testable import cmux

final class GhosttyTitleUpdateDispatcherTests: XCTestCase {
    @MainActor
    func testBurstPublishesOnlyLatestTitle() async {
        var published: [GhosttyTitleUpdate] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(automaticallySchedules: false) { updates in
            published.append(contentsOf: updates)
        }
        let tabId = UUID()
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())

        for sequence in 1...600 {
            await dispatcher.receive(GhosttyTitleUpdate(
                tabId: tabId,
                surfaceId: surfaceId,
                title: "spinner-\(sequence)",
                sourceSurfaceIdentifier: sourceIdentifier,
                sequence: UInt64(sequence)
            ))
        }
        await dispatcher.flushNow()

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.title, "spinner-600")
    }

    @MainActor
    func testDuplicatePublishedTitleDoesNotPublishAgain() async {
        var published: [GhosttyTitleUpdate] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(automaticallySchedules: false) { updates in
            published.append(contentsOf: updates)
        }
        let sourceIdentifier = ObjectIdentifier(NSObject())
        let first = GhosttyTitleUpdate(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "unchanged",
            sourceSurfaceIdentifier: sourceIdentifier,
            sequence: 1
        )

        await dispatcher.receive(first)
        await dispatcher.flushNow()
        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: first.tabId,
            surfaceId: first.surfaceId,
            title: first.title,
            sourceSurfaceIdentifier: sourceIdentifier,
            sequence: 2
        ))
        await dispatcher.flushNow()

        XCTAssertEqual(published.map(\.title), ["unchanged"])
    }

    @MainActor
    func testOutOfOrderSubmissionCannotRestoreStaleTitle() async {
        var published: [GhosttyTitleUpdate] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(automaticallySchedules: false) { updates in
            published.append(contentsOf: updates)
        }
        let tabId = UUID()
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())

        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "new",
            sourceSurfaceIdentifier: sourceIdentifier,
            sequence: 2
        ))
        await dispatcher.receive(GhosttyTitleUpdate(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "stale",
            sourceSurfaceIdentifier: sourceIdentifier,
            sequence: 1
        ))
        await dispatcher.flushNow()

        XCTAssertEqual(published.map(\.title), ["new"])
    }
}

@MainActor
final class RightSidebarModeShortcutMatcherTests: XCTestCase {
    func testOrdinaryTypingUsesCachedModifierBucketWithoutLookupOrLayoutWork() {
        var shortcutLookupCount = 0
        var layoutLookupCount = 0
        let matcher = RightSidebarModeShortcutMatcher(
            notificationCenter: NotificationCenter(),
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
            XCTAssertNil(matcher.modeShortcut(for: event, allowingAction: { _ in true }))
        }

        XCTAssertEqual(initialLookupCount, 5)
        XCTAssertEqual(shortcutLookupCount, initialLookupCount)
        XCTAssertEqual(layoutLookupCount, 0)
    }

    func testSettingsChangeRebuildsShortcutSnapshotOnce() {
        let center = NotificationCenter()
        var shortcutLookupCount = 0
        let matcher = RightSidebarModeShortcutMatcher(
            notificationCenter: center,
            shortcutProvider: { _ in
                shortcutLookupCount += 1
                return StoredShortcut(key: "b", command: true, shift: false, option: true, control: false)
            },
            availability: { _ in true },
            layoutCharacterProvider: { _, _ in nil }
        )

        XCTAssertEqual(shortcutLookupCount, 5)
        center.post(name: KeyboardShortcutSettings.didChangeNotification, object: nil)
        XCTAssertEqual(shortcutLookupCount, 10)
        _ = matcher.modeShortcut(for: makeKeyEvent(characters: "x", modifiers: []), allowingAction: { _ in true })
        XCTAssertEqual(shortcutLookupCount, 10)
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
