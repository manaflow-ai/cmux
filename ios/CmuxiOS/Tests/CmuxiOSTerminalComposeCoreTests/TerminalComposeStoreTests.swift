import CmuxiOSFeatureKit
import CmuxiOSTerminalComposeCore
import Foundation
import Testing

@MainActor
@Suite struct TerminalComposeStoreTests {
    let mac = HostID("host_mac")
    let other = HostID("host_other")

    final class Clock: @unchecked Sendable {
        var seconds: Double = 1_000
        func tick() -> Date {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
    }

    @Test func draftsAreKeyedByHostAndTerminal() {
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence())
        store.setDraft("on mac", for: TerminalDraftKey(host: mac, terminal: "term_1"))
        store.setDraft("on other", for: TerminalDraftKey(host: other, terminal: "term_1"))
        #expect(store.draft(for: TerminalDraftKey(host: mac, terminal: "term_1")) == "on mac")
        #expect(store.draft(for: TerminalDraftKey(host: other, terminal: "term_1")) == "on other")
        #expect(store.draft(for: TerminalDraftKey(host: mac, terminal: "term_2")) == "")
    }

    @Test func whitespaceRemovesAndClearRemoves() {
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence())
        let key = TerminalDraftKey(host: mac, terminal: "term_1")
        store.setDraft("hello", for: key)
        #expect(store.draftCount == 1)
        store.setDraft("  \n", for: key)
        #expect(store.draftCount == 0)
        store.setDraft("again", for: key)
        store.clearDraft(for: key)
        #expect(store.draft(for: key) == "")
    }

    @Test func evictsOldestEditBeyondTheCount() {
        let clock = Clock()
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence(),
                                         limits: TerminalComposeLimits(maxDrafts: 2), now: { clock.tick() })
        let first = TerminalDraftKey(host: mac, terminal: "term_1")
        let second = TerminalDraftKey(host: mac, terminal: "term_2")
        let third = TerminalDraftKey(host: mac, terminal: "term_3")
        store.setDraft("one", for: first)
        store.setDraft("two", for: second)
        store.setDraft("one edited", for: first)
        store.setDraft("three", for: third)
        #expect(store.draftCount == 2)
        #expect(store.draft(for: second) == "")
        #expect(store.draft(for: first) == "one edited")
        #expect(store.draft(for: third) == "three")
    }

    @Test func capsBytesOnACharacterBoundary() {
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence(),
                                         limits: TerminalComposeLimits(maxDraftBytes: 7))
        let key = TerminalDraftKey(host: mac, terminal: "term_1")
        // "ab" (2) + "日" (3) + "本" (3) = 8 bytes: the last character goes.
        let kept = store.setDraft("ab日本", for: key)
        #expect(kept == "ab日")
        #expect(store.draft(for: key) == "ab日")
    }

    @Test func persistsOnFlushOnly() throws {
        let persistence = MemoryTerminalComposePersistence()
        let key = TerminalDraftKey(host: mac, terminal: "term_1")
        let store = TerminalComposeStore(persistence: persistence)
        store.setDraft("keep me", for: key)
        store.recordSent("sent once")
        #expect(persistence.stored == nil)
        store.flush()
        #expect(persistence.stored != nil)

        let reloaded = TerminalComposeStore(persistence: persistence)
        #expect(reloaded.draft(for: key) == "keep me")
        #expect(reloaded.history == ["sent once"])
    }

    @Test func fileRoundTripAndCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileTerminalComposePersistence(url: directory.appendingPathComponent("compose.json"))
        let key = TerminalDraftKey(host: mac, terminal: "term_1")
        let store = TerminalComposeStore(persistence: persistence)
        store.setDraft("on disk", for: key)
        store.flush()
        #expect(TerminalComposeStore(persistence: persistence).draft(for: key) == "on disk")

        try Data("{not json".utf8).write(to: persistence.url)
        let fresh = TerminalComposeStore(persistence: persistence)
        #expect(fresh.draftCount == 0)
        #expect(fresh.history.isEmpty)
    }

    @Test func historyDedupesAndCaps() {
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence(),
                                         limits: TerminalComposeLimits(maxHistory: 3))
        for entry in ["a", "b", "c", "a", "d", "  "] { store.recordSent(entry) }
        #expect(store.history == ["c", "a", "d"])
    }

    @Test func clearAllForgetsEverything() {
        let persistence = MemoryTerminalComposePersistence()
        let store = TerminalComposeStore(persistence: persistence)
        store.setDraft("secret", for: TerminalDraftKey(host: mac, terminal: "term_1"))
        store.recordSent("secret prompt")
        store.flush()
        store.clearAll()
        #expect(store.draftCount == 0)
        #expect(store.history.isEmpty)
        #expect(persistence.stored == nil)
        #expect(TerminalComposeStore(persistence: persistence).draftCount == 0)
    }
}
