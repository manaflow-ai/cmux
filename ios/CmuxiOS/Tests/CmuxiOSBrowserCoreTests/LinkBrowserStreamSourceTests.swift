import CmuxBrowserStream
import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import Foundation
import Testing

@Suite("LinkBrowserStreamSource against a real MobileHost")
struct LinkBrowserStreamSourceTests {
    @Test func opensAStreamWithPageUpdatesAndVideo() async throws {
        let h = try await BrowserHostHarness.make()
        defer { Task { await h.shutdown() } }
        let session = try await h.source.open("tab_b1", on: HostID("h_mac1"))
        var states = await session.states().makeAsyncIterator()
        #expect(await states.next() == .streaming(width: 1178, height: 736))
        let pages = await session.pageUpdates()
        let updates = try await BrowserHostHarness.within {
            var seen: [BrowserPageUpdate] = []
            for await update in pages {
                seen.append(update)
                if seen.count == 3 { break }
            }
            return seen
        }
        #expect(updates.contains(.pageSize(width: 1440, height: 900)))
        #expect(updates.contains(.page(BrowserPageInfo(url: "https://example.com/", title: "Example", canGoBack: true))))
        #expect(updates.contains(.textFocus(true)))
        let samples = await session.videoSamples()
        let first = try await BrowserHostHarness.within {
            for await sample in samples { return sample }
            throw TimeoutError()
        }
        #expect(first.isKeyframe)
        #expect(first.refFrame == nil)
        #expect(first.codec == "h264")
        await session.close()
    }

    @Test func refusedSchemesComeBackAsRefusedReceipts() async throws {
        let h = try await BrowserHostHarness.make()
        defer { Task { await h.shutdown() } }
        let session = try await h.source.open("tab_b1", on: HostID("h_mac1"))
        let key = IntentKey()
        let refused = try await session.navigate(.load(URL(string: "file:///etc/hosts")!), key: key)
        #expect(refused == .refused(key: key, reason: "scheme"))
        let ok = try await session.navigate(.load(URL(string: "https://example.com/next")!), key: key)
        #expect(ok == .committed(key: key, revision: 0))
        #expect(await h.pages.attachment.loads == [URL(string: "https://example.com/next")!])
        await session.close()
    }

    @Test func inputArrivesAsRbEventsInOrder() async throws {
        let h = try await BrowserHostHarness.make()
        defer { Task { await h.shutdown() } }
        let session = try await h.source.open("tab_b1", on: HostID("h_mac1"))
        await session.send(.pointer(BrowserPointerEvent(kind: .down, x: 10, y: 20, clickCount: 2)))
        await session.send(.pointer(BrowserPointerEvent(kind: .up, x: 10, y: 20, clickCount: 2)))
        await session.send(.composition(text: "にほ", selection: 2..<2))
        await session.send(.commit("日本"))
        await session.send(.key(BrowserKeyEvent(down: true, code: "Enter", key: "Enter")))
        // A navigation round trip orders after the input on the same channel.
        _ = try await session.navigate(.load(URL(string: "https://example.com/sync")!), key: IntentKey())
        let inputs = await h.pages.attachment.inputs
        #expect(inputs.count == 5)
        #expect(inputs.first == .pointer(kind: .down, x: 10, y: 20, button: 0, buttons: 1, clickCount: 2, modifiers: [],
                                         pointerType: "touch"))
        #expect(inputs[2] == .imeSetComposition(text: "にほ", underlines: [RbUnderline(start: 0, end: 2)], selectionStart: 2,
                                                 selectionEnd: 2, replacement: nil))
        #expect(inputs[3] == .imeCommit(text: "日本", replacement: nil))
        await session.close()
    }

    @Test func unknownTabsAreNotFound() async throws {
        let h = try await BrowserHostHarness.make()
        defer { Task { await h.shutdown() } }
        await #expect(throws: FeatureSourceError.notFound("tab_zz")) {
            _ = try await h.source.open("tab_zz", on: HostID("h_mac1"))
        }
    }
}
