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
    /// The next N attaches answer "unknown surface" (a Mac host that just restarted).
    var failNextAttaches = 0
    /// `identify` advertises attach-initial-size.
    var initialSize = false
    /// The surface the terminal is on now (a daemon restart renumbers it).
    var liveSurface = 7
    /// `resolve-terminal` answers: terminal id to its surface (nil: the
    /// daemon does not know the command).
    var terminals: [String: Int]? = nil
    /// The next N `resolve-terminal` answers have a null surface (restoring).
    var restoring = 0

    var recorded: [[String: Any]] { lock.withLock { commands } }

    func respond(_ service: String, _ data: Data) -> [Data] {
        // A batch (`DaemonClient.requests`) is several lines in one write.
        data.split(separator: 0x0A).flatMap { respondLine(service, Data($0)) }
    }

    private func respondLine(_ service: String, _ line: Data) -> [Data] {
        guard service == "daemon", let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return [] }
        lock.withLock { commands.append(object) }
        func reply(_ data: [String: Any] = [:]) -> Data {
            Self.line(["id": id, "ok": true, "data": data])
        }
        switch cmd {
        case "identify" where initialSize:
            return [reply(["capabilities": ["attach-initial-size"]])]
        case "resolve-terminal":
            guard let terminals = lock.withLock({ self.terminals }) else {
                return [Self.line(["id": id, "ok": false, "error": "unknown command resolve-terminal"])]
            }
            let restoringNow: Bool = lock.withLock {
                guard restoring > 0 else { return false }
                restoring -= 1
                return true
            }
            if restoringNow { return [reply(["surface": NSNull(), "terminal_id": object["terminal_id"] ?? ""])] }
            guard let id2 = object["terminal_id"] as? String, let surface = terminals[id2] else {
                return [Self.line(["id": id, "ok": false, "error": "terminal_not_found"])]
            }
            return [reply(["surface": surface, "terminal_id": id2])]
        case "attach-surface":
            let fail: Bool = lock.withLock {
                guard failNextAttaches > 0 else { return false }
                failNextAttaches -= 1
                return true
            }
            if fail {
                // The replay a refusing daemon never sends; a stray event first, then the refusal.
                return [Self.line(["event": "output", "surface": 7, "data": Data("stale".utf8).base64EncodedString()]),
                        Self.line(["id": id, "ok": false, "error": "unknown surface 7"])]
            }
            let live = lock.withLock { liveSurface }
            guard object["surface"] as? Int == live else {
                return [Self.line(["id": id, "ok": false, "error": "unknown surface \(object["surface"] as? Int ?? -1)"])]
            }
            return [
                Self.line(["event": "vt-state", "surface": live, "cols": 80, "rows": 24,
                           "data": Data("hello\r\n$ ".utf8).base64EncodedString()]),
                reply(["lease": "l1"]),
                Self.line(["event": "output", "surface": live, "data": Data("\u{1B}[?1049hTUI".utf8).base64EncodedString()]),
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
        // A reset first (the mirror starts clean and places the Mac's screen), then the replay; surface 8 ignored.
        #expect(output == "\u{1B}chello\r\n$ \u{1B}[?1049hTUI")
        #expect(session.remoteRows == 24)
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

    /// Keystrokes go on their own input-lane channel; resizes stay on the
    /// attach channel (geometry authority belongs to the attaching client).
    @Test func keystrokesRideTheInputLane() async throws {
        let main = FakeTerminalDaemon()
        let lane = FakeTerminalDaemon()
        let mainLink = MockMacLink { service, line in main.respond(service, line) }
        let laneLink = MockMacLink { service, line in lane.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, open: {
            DaemonClient(channel: try await mainLink.openChannel(service: "daemon", args: [:]))
        }, openInput: {
            DaemonClient(channel: try await laneLink.openInputChannel(service: "daemon", args: [:]))
        })
        session.start { _ in }
        session.resize(columns: 80, rows: 30)
        try await waitUntil { session.isAttached }
        // The lane opens just after the attach; wait until it carries a send.
        var typed = 0
        for _ in 0..<50 where !lane.recorded.contains(where: { $0["cmd"] as? String == "send" }) {
            session.send(Data("x".utf8))
            typed += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lane.recorded.contains { $0["cmd"] as? String == "send" })
        #expect(!lane.recorded.contains { $0["cmd"] as? String == "resize-surface" })
        #expect(main.recorded.contains { $0["cmd"] as? String == "resize-surface" })
        // Every keystroke arrived exactly once, across both channels.
        let sent = (main.recorded + lane.recorded).filter { $0["cmd"] as? String == "send" }
            .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } }
            .reduce(into: Data()) { $0.append($1) }
        try await waitUntil {
            (main.recorded + lane.recorded).filter { $0["cmd"] as? String == "send" }
                .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) }?.count }.reduce(0, +) == typed
        }
        #expect(sent.allSatisfy { $0 == UInt8(ascii: "x") })
    }

    /// The screen shows "Connecting to <Mac>…" until the attach succeeds,
    /// never made-up output.
    @Test func reportsConnectingThenAttached() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.macName = "Studio"
        #expect(session.connectionState == .connecting(mac: "Studio"))
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        #expect(events.first == .connection(.connecting(mac: "Studio")))
        try await waitUntil { events.contains(.connection(.attached)) }
        #expect(session.connectionState == .attached)
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

    /// termqa V5-4: + → New Terminal made the open tab replay. The Mac sent
    /// `resized` at the grid the phone already mirrors (53x39): a change of
    /// the Mac's cell pixels only (`commit_geometry_for_runtime` sends a
    /// replay to byte mirrors for it). The phone's mirror already holds that
    /// state, so it keeps its screen: no reset, no second copy of the replay.
    @Test func aResizeAtTheSameGridDoesNotResetTheMirror() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 53, "rows": 39,
                                                "data": Data("screen".utf8).base64EncodedString()]))
        events.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 39,
                                                "replay": Data("screen".utf8).base64EncodedString()]))
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("more".utf8).base64EncodedString()]))
        #expect(!events.contains(.output(Data("\u{1B}c".utf8))))
        #expect(events == [.output(Data("more".utf8))])
        // A different grid still resets.
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 42,
                                                "replay": Data("fresh".utf8).base64EncodedString()]))
        #expect(events.contains(.output(Data("\u{1B}c".utf8))))
        #expect(events.last == .output(Data("fresh".utf8)))
        // And then the same grid again does not.
        events.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 42,
                                                "replay": Data("fresh".utf8).base64EncodedString()]))
        #expect(events.isEmpty)
    }

    @Test func resizedEventKeepsATUIWithoutAnOffOnFlicker() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "output", "surface": 7, "data": Data("\u{1B}[?1049h".utf8).base64EncodedString()]))
        events.removeAll()
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 24,
                                                "replay": Data("\u{1B}[?1049htop".utf8).base64EncodedString()]))
        #expect(!events.contains(.alternateScreen(false)))
        #expect(!events.contains(.alternateScreen(true)))
        #expect(session.isAlternateScreen)
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

    /// The link dropped (background, transport switch, Mac restart): the
    /// channel ends with no `detached` event. The tab must not die; when the
    /// link is back it attaches again, resets the mirror before the replay,
    /// and puts its size back.
    @Test func reattachesAfterTheLinkDrops() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached }
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "resize-surface" } }

        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        #expect(!events.contains(.exited(code: 0)), "a dropped link is not the end of the terminal")

        let before = events.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count == 2 }
        let after = Array(events[before...])
        let reset = after.firstIndex(of: .output(Data("\u{1B}c".utf8)))
        let replay = after.firstIndex(of: .output(Data("hello\r\n$ ".utf8)))
        #expect(reset != nil && replay != nil && reset! < replay!)
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 2)

        // Input typed after the reconnect goes out on the new channel.
        session.send(Data("x".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
    }

    /// termqa D3: right after the Mac's host restarts, a reattach can be refused
    /// ("unknown surface") for a moment. The screen keeps its last frame: no
    /// mirror reset and no error line until an attach succeeds, then the
    /// reset and the replay, in that order.
    @Test func aRefusedReattachKeepsTheLastFrameAndRetries() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "host restarted")
        try await waitUntil { !session.isAttached }

        daemon.failNextAttaches = 2
        let before = events.count
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        let after = Array(events[before...])
        let outputs = after.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }
        // Nothing reached the screen before the good attach: no reset, no "[unknown surface]" line, no stray output.
        #expect(outputs.first == "\u{1B}c")
        #expect(!outputs.contains { $0.contains("unknown surface") || $0.contains("stale") })
        #expect(outputs.contains("hello\r\n$ "))
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 4)
    }

    /// termqa D8: the Mac's own window sets this terminal's grid (39 rows),
    /// so the phone's 42 is overruled. A reattach attaches at the Mac's size
    /// and does not ask for 42 again: the PTY is not resized away and back
    /// (each resize made Codex redraw its whole transcript over the link).
    @Test func aReattachKeepsAnOverruledSize() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        session.start { _ in }
        session.resize(columns: 53, rows: 42)
        try await waitUntil { session.isAttached }
        let first = try #require(daemon.recorded.first { $0["cmd"] as? String == "attach-surface" })
        #expect(first["rows"] as? Int == 42)
        // The Mac keeps 39 rows.
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 53, "rows": 39,
                                                "replay": Data("x".utf8).base64EncodedString()]))
        await channels.last?.close(code: "link_closed", reason: "background")
        try await waitUntil { !session.isAttached }
        let resizesBefore = daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count
        session.reconnect()
        try await waitUntil { session.isAttached }
        let second = try #require(daemon.recorded.last { $0["cmd"] as? String == "attach-surface" })
        #expect(second["cols"] as? Int == 53)
        #expect(second["rows"] as? Int == 39)
        session.send(Data("x".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count == resizesBefore)
        // A new phone grid asks again.
        session.resize(columns: 53, rows: 40)
        try await waitUntil { daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count == resizesBefore + 1 }
    }

    /// The terminal channel says it is a phone before it attaches, so the
    /// Mac's daemon holds the grid when the phone's link drops (termqa V2-5:
    /// no resize away and back, so Codex keeps its scrollback).
    @Test func theTerminalChannelSaysItIsAPhoneBeforeAttaching() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(
            surface: 7,
            clientInfo: ["name": "Test iPhone", "kind": "ios", "device_kind": "iphone", "device_id": "d1"]
        ) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        var attached = false
        session.start { if $0 == .connection(.attached) { attached = true } }
        try await waitUntil { attached }
        let order = daemon.recorded.compactMap { $0["cmd"] as? String }
        let info = try #require(daemon.recorded.first { $0["cmd"] as? String == "set-client-info" })
        #expect(info["device_kind"] as? String == "iphone")
        #expect(order.firstIndex(of: "set-client-info")! < order.firstIndex(of: "attach-surface")!)
    }

    @Test func detachedEventEndsTheTerminal() async throws {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.handle(FakeTerminalDaemon.line(["event": "detached", "surface": 7, "reason": "closed"]))
        #expect(events.contains(.exited(code: 0)))
    }

    private func waitUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

final class ChannelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [any LinkChannel] = []
    func append(_ channel: any LinkChannel) { lock.withLock { channels.append(channel) } }
    var last: (any LinkChannel)? { lock.withLock { channels.last } }
}

/// Verifier round 3: every reattach logged `attach surface 14: unknown surface
/// 14` and retried it six times: the session of a tab closed earlier (its
/// host kept for the card) was attached again on every new link.
@Suite struct ReattachSurfacesTests {
    @Test func aClosedTabsSurfaceIsNotAttachedAgain() {
        #expect(DaemonTerminalSession.surfacesToReattach([14, 16, 17], tree: [16, 17]) == [16, 17])
    }

    @Test func beforeTheTreeIsKnownEverySessionReattaches() {
        #expect(DaemonTerminalSession.surfacesToReattach([14, 16], tree: nil) == [14, 16])
    }
}

/// transport-verify-20261019.md defect 2: after the Mac's daemon restarts it
/// numbers its surfaces again, so the phone's open terminal stayed
/// "Reattaching…" and printed `[unknown surface 15]`. A reattach finds the
/// terminal by its durable id (`resolve-terminal`), and a terminal the Mac no
/// longer has ends with a clear line instead of waiting forever.
@MainActor @Suite struct TerminalRenumberTests {
    private func waitUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    func session(_ daemon: FakeTerminalDaemon, _ channels: ChannelLog) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        return DaemonTerminalSession(surface: 7, terminalID: "term_a") {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
    }

    @Test func aReattachFollowsTheTerminalToItsNewSurface() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "Mac app restarted")
        try await waitUntil { !session.isAttached }

        // The daemon came back and put the terminal on surface 15.
        daemon.liveSurface = 15
        daemon.terminals = ["term_a": 15]
        let before = events.count
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        #expect(session.surface == 15)
        #expect(daemon.recorded.last { $0["cmd"] as? String == "attach-surface" }?["surface"] as? Int == 15)
        let after = events[before...].compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }
        #expect(!after.contains { $0.contains("unknown surface") })
        #expect(after.contains("hello\r\n$ "), "the new surface's replay shows")
        session.send(Data("x".utf8))
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "send" } }
        #expect(daemon.recorded.last { $0["cmd"] as? String == "send" }?["surface"] as? Int == 15)
    }

    @Test func aTerminalTheMacNoLongerHasEndsWithAClearLine() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "Mac app restarted")
        try await waitUntil { !session.isAttached }

        daemon.liveSurface = 15
        daemon.terminals = [:]
        session.reconnect()
        try await waitUntil(attempts: 400) { events.contains(.exited(code: 0)) }
        let text = events.compactMap { event -> String? in
            if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
            return nil
        }.joined()
        #expect(text.contains("no longer open on the Mac"))
        #expect(session.connectionState != .reattaching(mac: nil), "never stuck reattaching")
        // Never attached to whatever the old number names now.
        #expect(daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }.count == 1)
    }

    /// Review finding 1: a daemon still adopting its terminals answers a null
    /// surface for a moment; the reattach waits and attaches, never ends.
    @Test func aTerminalNotOnASurfaceYetIsWaitedFor() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.terminals = ["term_a": 7]
        let channels = ChannelLog()
        let session = session(daemon, channels)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "Mac app restarted")
        try await waitUntil { !session.isAttached }
        daemon.liveSurface = 15
        daemon.restoring = 2
        daemon.terminals = ["term_a": 15]
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        #expect(session.surface == 15)
        #expect(!events.contains(.exited(code: 0)))
    }

    @Test func aDaemonWithoutResolveStillReattachesByNumber() async throws {
        let daemon = FakeTerminalDaemon()
        let channels = ChannelLog()
        let session = session(daemon, channels)
        session.start { _ in }
        try await waitUntil { session.isAttached }
        await channels.last?.close(code: "link_closed", reason: "background")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil(attempts: 400) { session.isAttached }
        #expect(session.surface == 7)
    }
}
