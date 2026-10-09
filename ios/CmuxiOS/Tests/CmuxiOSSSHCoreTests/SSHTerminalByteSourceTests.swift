import CmuxiOSFeatureKit
import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import CmuxTerminalRenderCore
import Foundation
import Testing

@Suite struct SSHTerminalByteSourceTests {
    static let fast = SSHReconnectPolicy(initial: .milliseconds(1), maximum: .milliseconds(2), attempts: 2)

    /// Reads states until one matches.
    func waitFor(_ source: SSHTerminalByteSource, _ match: @Sendable (SSHSessionState) -> Bool) async -> SSHSessionState? {
        for await state in await source.states() where match(state) { return state }
        return nil
    }

    @Test func opensWithViewportPTYAndStreamsBytes() async throws {
        let channel = FakeShellChannel()
        let connector = FakeConnector([.open(channel)])
        let source = SSHTerminalByteSource(terminalID: "ssh-box", title: "box", connector: connector, policy: Self.fast)
        let stream = try await source.open(TerminalViewport(cols: 100, rows: 30, visible: true))
        _ = await waitFor(source) { $0 == .live }
        #expect(await connector.requests == ["100x30"])

        channel.emit(.stdout(Data("hi".utf8)))
        channel.emit(.stderr(Data("!".utf8)))
        var events: [String] = []
        for await event in stream {
            switch event {
            case .title(let title): events.append("title \(title)")
            case .path(let path, _): events.append("path \(path)")
            case .bytes(let data): events.append("bytes " + String(decoding: data, as: UTF8.self))
            default: events.append("other")
            }
            if events.count == 4 { break }
        }
        #expect(events == ["title box", "path direct", "bytes hi", "bytes !"])
    }

    @Test func windowChangeIsSentOnceAndInputGoesThrough() async throws {
        let channel = FakeShellChannel()
        let source = SSHTerminalByteSource(terminalID: "t", connector: FakeConnector([.open(channel)]), policy: Self.fast)
        _ = try await source.open(TerminalViewport(cols: 80, rows: 24, visible: true))
        _ = await waitFor(source) { $0 == .live }
        await source.viewportChanged(TerminalViewport(cols: 80, rows: 24, visible: false))
        await source.viewportChanged(TerminalViewport(cols: 120, rows: 40, visible: true))
        await source.viewportChanged(TerminalViewport(cols: 120, rows: 40, visible: true))
        #expect(channel.resizes == ["120x40"])
        try await source.send(Data("ls\r".utf8))
        #expect(channel.written == [Data("ls\r".utf8)])
    }

    @Test func sendWhileNotLiveThrowsOffline() async throws {
        let source = SSHTerminalByteSource(terminalID: "t", connector: FakeConnector([.fail(.authenticationFailed)]), policy: Self.fast)
        await #expect(throws: FeatureSourceError.offline) { try await source.send(Data("x".utf8)) }
        let stream = try await source.open(TerminalViewport(cols: 80, rows: 24, visible: true))
        var closedReason: String?
        for await event in stream { if case .closed(let reason) = event { closedReason = reason } }
        #expect(closedReason == "failed authenticationFailed")
        #expect(await source.currentState == .failed(.authenticationFailed))
    }

    @Test func droppedConnectionReconnectsWithTheNewestViewport() async throws {
        let first = FakeShellChannel()
        let second = FakeShellChannel()
        let connector = FakeConnector([.open(first), .fail(.network), .open(second)])
        let source = SSHTerminalByteSource(terminalID: "t", connector: connector,
                                           policy: SSHReconnectPolicy(initial: .milliseconds(1), maximum: .milliseconds(2), attempts: 3))
        _ = try await source.open(TerminalViewport(cols: 80, rows: 24, visible: true))
        _ = await waitFor(source) { $0 == .live }
        await source.viewportChanged(TerminalViewport(cols: 90, rows: 20, visible: true))
        let states = await source.states()
        first.emit(.closed)
        var seen: [SSHSessionState] = []
        for await state in states {
            seen.append(state)
            if seen.count > 1 && state == .live { break }
        }
        #expect(seen.contains(.reconnecting(attempt: 1, delay: .milliseconds(1))))
        #expect(seen.contains(.reconnecting(attempt: 2, delay: .milliseconds(2))))
        #expect(first.closed)
        #expect(await connector.requests == ["80x24", "90x20", "90x20"])
        try await source.send(Data("a".utf8))
        #expect(second.written == [Data("a".utf8)])
    }

    @Test func remoteExitEndsWithoutReconnect() async throws {
        let channel = FakeShellChannel()
        let connector = FakeConnector([.open(channel)])
        let source = SSHTerminalByteSource(terminalID: "t", connector: connector, policy: Self.fast)
        let stream = try await source.open(TerminalViewport(cols: 80, rows: 24, visible: true))
        _ = await waitFor(source) { $0 == .live }
        channel.emit(.exitStatus(0))
        channel.emit(.closed)
        var reason: String?
        for await event in stream { if case .closed(let text) = event { reason = text } }
        #expect(reason == "exited 0")
        #expect(await connector.requests.count == 1)
    }

    @Test func retriesRunOutAsNetworkFailure() async throws {
        let connector = FakeConnector([.fail(.network), .fail(.network), .fail(.network)])
        let source = SSHTerminalByteSource(terminalID: "t", connector: connector, policy: Self.fast)
        let stream = try await source.open(TerminalViewport(cols: 80, rows: 24, visible: true))
        for await _ in stream {}
        #expect(await source.currentState == .failed(.network))
        #expect(await connector.requests.count == 3)
    }

    @Test func closeEndsTheStreamAndClosesTheShell() async throws {
        let channel = FakeShellChannel()
        let source = SSHTerminalByteSource(terminalID: "t", connector: FakeConnector([.open(channel)]), policy: Self.fast)
        let stream = try await source.open(TerminalViewport(cols: 80, rows: 24, visible: true))
        _ = await waitFor(source) { $0 == .live }
        await source.close()
        var reason: String?
        for await event in stream { if case .closed(let text) = event { reason = text } }
        #expect(reason == "closed")
        #expect(channel.closed)
        #expect(await source.currentState == .closed)
    }
}
