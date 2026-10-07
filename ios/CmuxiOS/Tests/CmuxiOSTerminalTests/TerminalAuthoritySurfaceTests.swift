import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing
import UIKit
@testable import CmuxiOSTerminal

/// The source's authority picks the surface's I/O mode: a `.local` surface
/// (SSH, fixtures) is the only parser and answers terminal queries through
/// its input path; a `.host` mirror drops them (the host answered once).
@MainActor
@Suite(.serialized) struct TerminalAuthoritySurfaceTests {
    private func surface(_ authority: TerminalAuthority) throws -> (UIWindow, GhosttyTerminalView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = GhosttyTerminalView(frame: window.bounds, authority: authority)
        window.addSubview(view)
        window.isHidden = false
        try #require(view.surface != nil, "surface: \(view.diagnostics)")
        return (window, view)
    }

    /// Waits for every queued output call, then for main-queue deliveries.
    private func drain(_ view: GhosttyTerminalView) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.enqueueOutput { _ in continuation.resume() }
        }
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func replies(to query: String, authority: TerminalAuthority) async throws -> [UInt8] {
        let (window, view) = try surface(authority)
        defer { window.isHidden = true }
        var out: [UInt8] = []
        view.onInput = { out += Array($0) }
        view.enqueueOutput { $0.feed(Data(query.utf8)) }
        await drain(view)
        return out
    }

    @Test func localSurfaceAnswersDeviceAttributes() async throws {
        let reply = try await replies(to: "\u{1B}[c", authority: .local)
        #expect(reply.starts(with: Array("\u{1B}[?".utf8)), "DA1 reply: \(reply)")
    }

    @Test func hostMirrorDropsReplies() async throws {
        #expect(try await replies(to: "\u{1B}[c\u{1B}[6n", authority: .host).isEmpty)
    }

    @Test func localSessionFeedsRawBytes() async throws {
        let (window, view) = try surface(.local)
        defer { window.isHidden = true }
        let source = StubLocalSource()
        let session = TerminalSession(source: source, view: view)
        session.start()
        await source.opened()
        source.emit(.bytes(Data("hello from ssh\r\n".utf8)))
        try? await Task.sleep(for: .milliseconds(50))
        await drain(view)
        view.selectAll(nil)
        #expect(view.selectedText?.contains("hello from ssh") == true, "\(view.selectedText ?? "nil")")
        session.stop()
    }
}

/// A `.local` source driven by the test.
@MainActor
private final class StubLocalSource: TerminalByteSource {
    nonisolated let authority: TerminalAuthority = .local
    nonisolated let terminalID = "stub"
    private var continuation: AsyncStream<TerminalSourceEvent>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open(_ viewport: TerminalViewport) async throws -> AsyncStream<TerminalSourceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TerminalSourceEvent.self)
        self.continuation = continuation
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return stream
    }

    func opened() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func emit(_ event: TerminalSourceEvent) { continuation?.yield(event) }
    func send(_ input: Data) async throws {}
    func viewportChanged(_ viewport: TerminalViewport) async {}
    func requestSnapshot(_ request: SnapshotRequest) async throws {}
    func close() async { continuation?.finish() }
}
