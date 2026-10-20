import CnxTransport
import Foundation
import Testing
@testable import CnxBrowserStream

@Suite struct AnnexBTests {
    @Test func splitsStartCodesAndBuildsAVCC() {
        let sps: [UInt8] = [0x67, 1, 2]
        let pps: [UInt8] = [0x68, 3]
        let idr: [UInt8] = [0x65, 9, 9, 9]
        let aud: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
        let start4: [UInt8] = [0, 0, 0, 1]
        let start3: [UInt8] = [0, 0, 1]
        var stream: [UInt8] = aud
        stream += start4 + sps
        stream += start3 + pps
        stream += start4 + idr
        let bytes = Data(stream)
        let unit = AnnexBAccessUnit(bytes)
        #expect(unit.sps == Data(sps))
        #expect(unit.pps == Data(pps))
        #expect(unit.isIDR)
        #expect(unit.units == [Data(idr)])
        let length: [UInt8] = [0, 0, 0, 4]
        #expect(unit.avcc == Data(length + idr))
        let p = AnnexBAccessUnit(Data([0, 0, 1, 0x41, 7, 7]))
        #expect(!p.isIDR && p.sps == nil && p.units == [Data([0x41, 7, 7])])
    }
}

@Suite struct WireTests {
    func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    @Test func screenCapsTheScaleAtTwo() {
        let screen = RemoteBrowserWire.Screen(points: CGSize(width: 402, height: 700.4), screenScale: 3)
        #expect(screen == .init(cssWidth: 402, cssHeight: 700, scale: 2))
        let open = object(RemoteBrowserWire().open(tab: "s4", viewer: "phone", screen: screen))
        #expect(open["t"] as? String == "rb.open")
        #expect((open["screen"] as? [String: Any])?["css_width"] as? Int == 402)
    }

    @Test func theOverlayNamesTheMediaLanesCarrier() {
        #expect(BrowserStreamStats.carrier(videoTrack: true, transport: .webRTC) == "track")
        #expect(BrowserStreamStats.carrier(videoTrack: true, transport: .wireGuard) == "wg-rtp")
        #expect(BrowserStreamStats.carrier(videoTrack: false, transport: .wireGuard) == "channel")
        #expect(BrowserStreamStats().videoCarrier == "channel")
    }

    @Test func inputEventsMatchTheRbSchema() {
        let wire = RemoteBrowserWire()
        let down = object(wire.pointer("down", x: 10, y: 20, buttons: 1))
        #expect(down["e"] as? String == "pointer" && down["kind"] as? String == "down" && down["click_count"] as? Int == 1)
        let wheel = object(wire.wheel(x: 1, y: 2, dx: 0, dy: -30, phase: "changed", momentum: "none"))
        #expect(wheel["precise"] as? Bool == true && wheel["dy"] as? Double == -30)
        let commit = object(wire.commit("héllo"))
        #expect(commit["e"] as? String == "ime_commit" && commit["text"] as? String == "héllo" && commit["replacement"] is NSNull)
        let key = object(wire.key("Backspace", key: "Backspace", down: true))
        #expect(key["code"] as? String == "Backspace" && (key["edit_commands"] as? [Any])?.isEmpty == true)
    }
}

final class FakeStream: BrowserStreamConnection, @unchecked Sendable {
    let lock = NSLock()
    var messages: [[String: Any]] = []
    var inputs: [[String: Any]] = []
    var closed = false

    func send(message: Data) throws {
        lock.withLock { messages.append((try? JSONSerialization.jsonObject(with: message) as? [String: Any]) ?? [:]) }
    }
    func send(input: Data, mustDeliver: Bool) throws {
        lock.withLock { inputs.append((try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]) }
    }
    func requestKeyframe() {}
    func noteDecode(micros: UInt32) {}
    func stats() -> BrowserStreamStats { BrowserStreamStats() }
    func nowMicros() -> UInt64 { 0 }
    func close() { lock.withLock { closed = true } }
    var sent: [String] { lock.withLock { messages.compactMap { $0["t"] as? String } } }
}

final class SinkBox: @unchecked Sendable {
    let lock = NSLock()
    var sinks: [any BrowserStreamSink] = []
    var last: (any BrowserStreamSink)? { lock.withLock { sinks.last } }
}

@MainActor @Suite struct ModelTests {
    func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func opensAtThePhonesSizeAndFollowsThePage() async throws {
        let stream = FakeStream()
        let box = SinkBox()
        let model = StreamedBrowserModel(tab: "s4", url: URL(string: "https://example.com")) { sink in
            box.lock.withLock { box.sinks.append(sink) }
            return stream
        }
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(box.last)
        #expect(model.phase == .connecting)
        sink.browserMessage(Data(#"{"t":"welcome","caps":["input.service"]}"#.utf8))
        await settle()
        #expect(stream.sent == ["rb.open", "rb.visibility"])
        sink.browserMessage(Data(#"{"t":"rb.page","url":"https://example.org/a","title":"A","loading":true,"can_go_back":true,"can_go_forward":false}"#.utf8))
        await settle()
        #expect(model.url?.absoluteString == "https://example.org/a" && model.title == "A" && model.isLoading && model.canGoBack)
        #expect(model.host == "example.org")
        model.layout(points: CGSize(width: 402, height: 500), screenScale: 3)
        model.goBack()
        model.reloadOrStop()
        model.navigate(to: "swift.org")
        #expect(stream.sent == ["rb.open", "rb.visibility", "rb.screen", "rb.history", "rb.history", "rb.navigate"])
        #expect(stream.lock.withLock { stream.messages[4]["op"] as? String } == "stop")
        #expect(stream.lock.withLock { stream.messages[5]["url"] as? String } == "https://swift.org")
        let (x, y) = model.css(CGPoint(x: 201, y: 250), in: CGSize(width: 402, height: 500))
        #expect(x == 201 && y == 250)
        // A dropped stream waits, then opens again on the next link.
        sink.browserClosed(code: "link_closed", reason: "")
        await settle()
        if case .waiting = model.phase {} else { Issue.record("expected waiting") }
        model.reconnect()
        await settle()
        #expect(box.lock.withLock { box.sinks.count } == 2)
    }

    @Test func aRefusedOpenSaysWhy() async {
        let model = StreamedBrowserModel(tab: "s4", url: nil) { _ in throw LinkError(code: "unavailable", message: "browser host: exited") }
        model.layout(points: CGSize(width: 300, height: 600), screenScale: 2)
        for _ in 0..<200 where model.phase == .connecting { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.phase == .waiting("browser host: exited"))
    }

    /// A Mac with no browser host (this build's code, or an older Mac's words) is an
    /// honest state, never the raw reason.
    @Test func aMacWithoutABrowserHostIsUnavailable() async {
        for error in [LinkError(code: "no_browser_host", message: "this Mac does not stream browser tabs"),
                      LinkError(code: "unavailable", message: "this build has no browser host")] {
            let model = StreamedBrowserModel(tab: "s5", url: nil) { _ in throw error }
            model.layout(points: CGSize(width: 300, height: 600), screenScale: 2)
            for _ in 0..<200 where model.phase == .connecting { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(model.phase == .unavailable)
        }
    }
}

/// A Mac without a browser host reads as an honest state, never its raw reason.
@Suite struct NoBrowserHostTests {
    @Test func theMacsMissingHostIsRecognized() {
        #expect(LinkErrorText.noBrowserHost(LinkError(code: "no_browser_host", message: "this Mac does not stream browser tabs")))
        #expect(LinkErrorText.noBrowserHost(LinkError(code: "unavailable", message: "this build has no browser host")))
        #expect(!LinkErrorText.noBrowserHost(LinkError(code: "unavailable", message: "browser host vanished")))
        #expect(!LinkErrorText.noBrowserHost(LinkError(code: "no-link", message: "Not connected to the Mac")))
    }
}

/// Parity findings 4 and 5 (verify/parity-mac.md): Forward right after Back, and the address
/// while a navigation loads.
@MainActor @Suite struct BrowserHistoryTests {
    func page(_ url: String, loading: Bool, back: Bool, forward: Bool) -> RemoteBrowserPage {
        RemoteBrowserPage(json: ["t": "rb.page", "url": url, "title": "", "loading": loading, "can_go_back": back, "can_go_forward": forward])!
    }

    func model() async throws -> (StreamedBrowserModel, FakeStream) {
        let stream = FakeStream()
        let box = SinkBox()
        let model = StreamedBrowserModel(tab: "s4", url: nil) { sink in
            box.lock.withLock { box.sinks.append(sink) }
            return stream
        }
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(box.last)
        sink.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        for _ in 0..<20 { await Task.yield() }
        return (model, stream)
    }

    func ops(_ stream: FakeStream) -> [String] {
        stream.lock.withLock { stream.messages.filter { $0["t"] as? String == "rb.history" }.compactMap { $0["op"] as? String } }
    }

    /// Finding 5: the browser reports the old history while Back loads, so Forward stayed
    /// disabled (or was ignored) until a second tap. Forward is offered at once, and a tap
    /// before Back commits is sent once it does, exactly once.
    @Test func forwardRightAfterBackNeedsOneTap() async throws {
        let (model, stream) = try await model()
        model.apply(page("https://iana.org/", loading: false, back: true, forward: false))
        model.goBack()
        #expect(model.canGoForward)
        // The Mac starts loading the previous page and still reports no forward entry.
        model.apply(page("https://iana.org/", loading: true, back: true, forward: false))
        #expect(model.canGoForward)
        model.goForward()
        #expect(ops(stream) == ["back"])
        model.apply(page("https://example.com/", loading: false, back: false, forward: true))
        #expect(ops(stream) == ["back", "forward"])
        #expect(model.canGoBack)
        model.apply(page("https://example.com/", loading: true, back: false, forward: true))
        model.apply(page("https://iana.org/", loading: false, back: true, forward: false))
        #expect(ops(stream) == ["back", "forward"])
        #expect(model.canGoBack && !model.canGoForward)
    }

    /// A step the Mac committed without a loading report (a cached page) still counts.
    @Test func aCachedStepCommitsOnTheNewAddress() async throws {
        let (model, stream) = try await model()
        model.apply(page("https://iana.org/", loading: false, back: true, forward: false))
        model.goBack()
        model.apply(page("https://example.com/", loading: false, back: false, forward: true))
        model.goForward()
        #expect(ops(stream) == ["back", "forward"])
    }

    /// Finding 4: a new tab reports about:blank while the typed address loads; the address
    /// stays the one asked for, then follows the page.
    @Test func theAddressIsTheOneAskedForWhileItLoads() async throws {
        let (model, _) = try await model()
        model.apply(page("about:blank", loading: false, back: false, forward: false))
        model.navigate(to: "example.com")
        model.apply(page("about:blank", loading: true, back: false, forward: false))
        #expect(model.url?.absoluteString == "https://example.com" && model.host == "example.com")
        model.apply(page("https://example.com/", loading: false, back: true, forward: false))
        #expect(model.url?.absoluteString == "https://example.com/")
        // Later reports follow the page again.
        model.apply(page("https://example.com/next", loading: false, back: true, forward: false))
        #expect(model.host == "example.com" && model.url?.path() == "/next")
    }
}
