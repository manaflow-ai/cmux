import AppKit
import Testing
@testable import cmux

@Suite("Ghostty title update dispatcher")
@MainActor
struct GhosttyTitleUpdateDispatcherTests {
    @Test func burstPublishesOnlyLatestTitle() async {
        var published: [GhosttyTitleUpdate] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(schedule: { _, _ in
            {}
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
                sourceSurfaceIdentifier: sourceIdentifier,
                sequence: UInt64(sequence)
            ))
        }
        await dispatcher.flushNow()

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

        #expect(published.map(\.title) == ["unchanged"])
    }

    @Test func outOfOrderSubmissionCannotRestoreStaleTitle() async {
        var published: [GhosttyTitleUpdate] = []
        let dispatcher = GhosttyTitleUpdateDispatcher(schedule: { _, _ in
            {}
        }) { updates in
            published.append(contentsOf: updates)
        }
        let tabId = UUID()
        let surfaceId = UUID()
        let source = NSObject()
        let sourceIdentifier = ObjectIdentifier(source)

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

        #expect(published.map(\.title) == ["new"])
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
