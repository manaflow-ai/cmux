import CnxTerminal
import CnxTransport
import Foundation
import Testing
@testable import CnxLive

/// A cmux-tui daemon stand-in for one PTY surface: answers `identify`,
/// `attach-surface` (vt-state replay first, then the reply), `send` and
/// `resize-surface`, and records every command.
final class FakeTerminalDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String: Any]] = []

    var recorded: [[String: Any]] { lock.withLock { commands } }

    func respond(_ service: String, _ line: Data) -> [Data] {
        guard service == "daemon", let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return [] }
        lock.withLock { commands.append(object) }
        func reply(_ data: [String: Any] = [:]) -> Data {
            Self.line(["id": id, "ok": true, "data": data])
        }
        switch cmd {
        case "attach-surface":
            guard object["surface"] as? Int == 7 else { return [Self.line(["id": id, "ok": false, "error": "unknown surface"])] }
            return [
                Self.line(["event": "vt-state", "surface": 7, "cols": 80, "rows": 24,
                           "data": Data("hello\r\n$ ".utf8).base64EncodedString()]),
                reply(["lease": "l1"]),
                Self.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049hTUI".utf8).base64EncodedString()]),
                Self.line(["event": "output", "surface": 8, "data": Data("other".utf8).base64EncodedString()]),
            ]
        default:
            return [reply()]
        }
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

@MainActor @Suite struct DaemonTerminalSessionTests {
    @Test func attachesReplaysAndForwardsInput() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { events.contains(.alternateScreen(true)) }
        let output = events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(output == "hello\r\n$ \u{1B}[?1049hTUI")  // surface 8 ignored
        #expect(session.isAlternateScreen)

        session.send(Data("ls\r".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        let send = try #require(daemon.recorded.first { $0["cmd"] as? String == "send" })
        #expect(send["surface"] as? Int == 7)
        #expect(send["bytes"] as? String == Data("ls\r".utf8).base64EncodedString())
        let resize = try #require(daemon.recorded.first { $0["cmd"] as? String == "resize-surface" })
        #expect(resize["cols"] as? Int == 54)
        #expect(resize["rows"] as? Int == 42)
        // The resize waited for the attach.
        let order = daemon.recorded.compactMap { $0["cmd"] as? String }
        #expect(order.firstIndex(of: "attach-surface")! < order.firstIndex(of: "resize-surface")!)
    }

    @Test func resizedEventResetsTheMirror() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049h".utf8).base64EncodedString()]))
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 100, "rows": 30,
                                                "replay": Data("fresh".utf8).base64EncodedString()]))
        #expect(events.contains(.alternateScreen(false)))
        #expect(events.contains(.output(Data("\u{1B}c".utf8))))
        #expect(events.last == .output(Data("fresh".utf8)))
    }

    @Test func attachFailureIsShownInTheTerminal() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 9) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.lastError != nil }
        #expect(session.lastError?.contains("unknown surface") == true)
        #expect(events.contains { if case .output = $0 { true } else { false } })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
