import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A mirrored workspace's tabs must stay in the order of the tmux session's windows when
/// something on the host reorders them with `move-window` or `swap-window`.
@MainActor
@Suite(.serialized) struct RemoteTmuxTabOrderFollowsTmuxTests {
    /// tmux reports a `move-window` inside a session as `%window-add`, `%session-window-changed`
    /// and `%window-close`, all for the moved window (measured on tmux 3.7b, on a client attached
    /// to that session and on one whose session has the window linked in). tmux sends
    /// `%window-close` only when the window is still in the client's session after the unlink;
    /// a window that left it arrives as `%unlinked-window-close`. Treating the first as a close
    /// destroyed the tab and built a new one at the end of the strip.
    @Test func moveWindowKeepsTheTabAndTakesTheNewPlace() throws {
        let harness = try threeWindowHarness()
        defer { harness.tearDown() }
        #expect(tabWindowOrder(harness) == [1, 2, 3])
        let panelsBefore = harness.sessionMirror.panelIdByWindow

        // `move-window -s '=work:@1' -t '=work:9'` on the host: @1 is now the last window.
        feed(harness.connection, "%window-add @1\n%session-window-changed $0 @1\n%window-close @1\n")
        answerPendingCommands(
            harness.connection,
            windowLines: [Self.windowLine(2), Self.windowLine(3), Self.windowLine(1)]
        )

        #expect(
            harness.sessionMirror.panelIdByWindow == panelsBefore,
            "moving a window inside its session must not close and recreate its tab"
        )
        #expect(tabWindowOrder(harness) == [2, 3, 1])
    }

    /// A workspace that ends up with a tab tmux does not own (the terminal cmux opens when a
    /// workspace's last tab closes, for one) must still follow tmux's order for the rest.
    @Test func aTabTmuxDoesNotOwnDoesNotFreezeTheOrder() throws {
        let harness = try threeWindowHarness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        // A mirror routes new terminals to tmux, so open the local one as a plain workspace would.
        workspace.isRemoteTmuxMirror = false
        let local = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
        workspace.isRemoteTmuxMirror = true
        let localTab = try #require(workspace.surfaceIdFromPanelId(local.id))
        #expect(workspace.bonsplitController.reorderTab(localTab, toIndex: 0))

        // `swap-window -s '=work:@1' -t '=work:@3'`, then any re-read of the window list.
        feed(harness.connection, "%window-add @3\n")
        answerPendingCommands(
            harness.connection,
            windowLines: [Self.windowLine(3), Self.windowLine(2), Self.windowLine(1)]
        )

        let tabs = workspace.bonsplitController.tabs(inPane: pane).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
        #expect(tabs.first == local.id, "the tab tmux does not own keeps its place")
        #expect(tabWindowOrder(harness) == [3, 2, 1])
    }

    /// `swap-window` sends no window notification at all (measured on tmux 3.7b, on both kinds
    /// of client). The only report of it is a format subscription whose value changes, so the
    /// subscriptions a stream sets up on attach must cover the window order. This replays what a
    /// shared view stream writes on attach into a real tmux client attached to a view session
    /// holding linked windows, swaps two windows in their home session, and hands what tmux
    /// sent back to the stream.
    @Test(.enabled(if: IsolatedTmuxServer.binary != nil))
    func swapWindowReachesTheViewStream() throws {
        let server = try IsolatedTmuxServer()
        defer { server.stop() }
        let viewName = "cmux-view-taborder"
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        try server.run(["new-window", "-d", "-t", "=work:"])
        try server.run(["new-window", "-d", "-t", "=work:"])
        try server.run(["new-session", "-d", "-s", viewName, "-x", "80", "-y", "24"])
        let homeWindows = try server.windowIds(session: "work")
        for id in homeWindows {
            try server.run(["link-window", "-d", "-s", id, "-t", "=\(viewName):"])
        }

        // The swap names the home session: a bare window id can resolve to the view, which
        // holds the same windows.
        let after = try notificationsAfterSwap(
            server: server,
            session: viewName,
            attachCommands: Self.attachCommands(sessionName: viewName, sharedView: true),
            swap: ("=work:\(homeWindows[0])", "=work:\(homeWindows[2])")
        )

        let consumer = AttachedStream(sessionName: viewName, sharedView: true)
        defer { consumer.close() }
        var topologyNotifies = 0
        let token = consumer.connection.addObserver(onTopologyChanged: { topologyNotifies += 1 })
        defer { consumer.connection.removeObserver(token) }
        feed(consumer.connection, after.joined(separator: "\n") + "\n")
        #expect(topologyNotifies > 0, "the view must re-read the server after a swap; tmux sent \(after)")
    }

    /// The same for a stream attached straight to the session being reordered.
    @Test(.enabled(if: IsolatedTmuxServer.binary != nil))
    func swapWindowReachesASessionStream() throws {
        let server = try IsolatedTmuxServer()
        defer { server.stop() }
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        try server.run(["new-window", "-d", "-t", "=work:"])
        try server.run(["new-window", "-d", "-t", "=work:"])
        let windows = try server.windowIds(session: "work")

        let after = try notificationsAfterSwap(
            server: server,
            session: "work",
            attachCommands: Self.attachCommands(sessionName: "work", sharedView: false),
            swap: ("=work:\(windows[0])", "=work:\(windows[2])")
        )

        let consumer = AttachedStream(sessionName: "work", sharedView: false)
        defer { consumer.close() }
        // Settle the attach's own commands so a new window-list request is visible.
        answerPendingCommands(consumer.connection, windowLines: [])
        consumer.connection.windowOrder = windows.compactMap { Int($0.dropFirst()) }
        let pendingBefore = consumer.connection.pendingCommandKindsForTesting.filter(Self.isWindowList).count
        feed(consumer.connection, after.joined(separator: "\n") + "\n")
        let pendingAfter = consumer.connection.pendingCommandKindsForTesting.filter(Self.isWindowList).count
        #expect(pendingAfter > pendingBefore, "the stream must re-read its windows after a swap; tmux sent \(after)")
    }

    // MARK: - Helpers

    private static func windowLine(_ id: Int) -> String {
        "@\(id) f92f,80x24,0,0,\(id * 11) f92f,80x24,0,0,\(id * 11) [] w\(id)"
    }

    private static func rects(_ id: Int) -> [String] {
        ["%\(id * 11) 0 0 80 24 1 off :zsh"]
    }

    private static func isWindowList(_ kind: RemoteTmuxControlCommandKind) -> Bool {
        if case .listWindows = kind { return true }
        return false
    }

    private func threeWindowHarness() throws -> RemoteTmuxSessionMirrorLayoutHarness {
        try RemoteTmuxSessionMirrorLayoutHarness(
            initialWindowLines: [Self.windowLine(1), Self.windowLine(2), Self.windowLine(3)],
            initialRectsByWindow: [1: Self.rects(1), 2: Self.rects(2), 3: Self.rects(3)]
        )
    }

    /// The tmux windows behind the workspace's tabs, left to right.
    private func tabWindowOrder(_ harness: RemoteTmuxSessionMirrorLayoutHarness) -> [Int] {
        let workspace = harness.workspace
        guard let pane = workspace.bonsplitController.allPaneIds.first else { return [] }
        return workspace.bonsplitController.tabs(inPane: pane).compactMap { tab in
            workspace.panelIdFromSurfaceId(tab.id).flatMap { harness.sessionMirror.windowIdByPanel[$0] }
        }
    }

    private func feed(_ connection: RemoteTmuxControlConnection, _ text: String) {
        var parser = RemoteTmuxControlStreamParser()
        for message in parser.feed(Data(text.utf8)) {
            connection.handleMessageForTesting(message)
        }
    }

    /// Answers every queued command: a window list with `windowLines`, each rects fetch with
    /// that window's single pane, anything else with an empty block.
    private func answerPendingCommands(_ connection: RemoteTmuxControlConnection, windowLines: [String]) {
        var answered = 0
        while let kind = connection.pendingCommandKindsForTesting.first, answered < 200 {
            answered += 1
            let lines: [String]
            switch kind {
            case .listWindows: lines = windowLines
            case let .paneRects(windowId, _): lines = Self.rects(windowId)
            default: lines = []
            }
            connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: lines, isError: false))
        }
    }

    /// Every command a stream writes once its attach block drains.
    private static func attachCommands(sessionName: String, sharedView: Bool) -> [String] {
        let stream = AttachedStream(sessionName: sessionName, sharedView: sharedView)
        return stream.closeAndReadCommands()
    }

    /// Attaches a real control client, replays `attachCommands`, waits for the subscriptions to
    /// report their first values, swaps two windows, and returns the notifications tmux sent
    /// about it. Fails if tmux sent nothing.
    private func notificationsAfterSwap(
        server: IsolatedTmuxServer,
        session: String,
        attachCommands: [String],
        swap: (String, String)
    ) throws -> [String] {
        let client = try server.attachControlClient(session: session)
        defer { client.stop() }
        for command in attachCommands { client.write(command) }
        let subscriptions = attachCommands.filter { $0.hasPrefix("refresh-client -B") }.count
        // tmux checks subscriptions once a second and reports each one's first value. Without
        // the full baseline, a late first value would land after `mark` and pass the swap check
        // on its own. The deadline only bounds the failure path.
        let baseline = client.waitForLines(timeout: 15) { lines in
            lines.filter { $0.hasPrefix("%subscription-changed ") }.count >= subscriptions
        }
        let baselineCount = baseline.filter { $0.hasPrefix("%subscription-changed ") }.count
        try #require(
            baselineCount >= subscriptions,
            "only \(baselineCount) of \(subscriptions) subscriptions reported a first value before the swap"
        )
        let mark = client.lines.count
        try server.run(["swap-window", "-d", "-s", swap.0, "-t", swap.1])
        let lines = client.waitForLines(timeout: 4) { lines in
            lines.dropFirst(mark).contains { $0.hasPrefix("%subscription-changed ") }
        }
        let after = Array(lines.dropFirst(mark)).filter { !$0.hasPrefix("%output ") }
        try #require(
            after.contains { $0.hasPrefix("%subscription-changed ") },
            "tmux reported nothing about the swap to this client: \(after)"
        )
        return after
    }
}

/// A control connection in control mode with its attach block drained, writing into a pipe.
@MainActor
private final class AttachedStream {
    let connection: RemoteTmuxControlConnection
    private let pipe = Pipe()
    private let writer: RemoteTmuxControlPipeWriter

    init(sessionName: String, sharedView: Bool) {
        connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@taborder-test"), sessionName: sessionName
        )
        connection.isSharedViewStream = sharedView
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-taborder-test",
            maxPendingBytes: 1 << 20,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        var parser = RemoteTmuxControlStreamParser()
        for message in parser.feed(Data("\u{1b}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8)) {
            connection.handleMessageForTesting(message)
        }
    }

    /// Closes the writer and returns every command it was given, one per line.
    func closeAndReadCommands() -> [String] {
        writer.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        close()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .flatMap { $0.components(separatedBy: " ; ") }
            .filter { !$0.isEmpty }
    }

    func close() {
        connection.stop()
        writer.close()
        try? pipe.fileHandleForReading.close()
    }
}

/// A tmux server on its own socket, so nothing here can reach a server the user runs.
private final class IsolatedTmuxServer {
    static let binary: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    let directory: URL
    private var socket: String { directory.appendingPathComponent("s").path }

    init() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-taborder-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func process(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.binary))
        process.arguments = ["-S", socket, "-f", "/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment["TMUX_TMPDIR"] = directory.path
        process.environment = environment
        return process
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = try process(arguments)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        try #require(process.terminationStatus == 0, "tmux \(arguments) failed: \(text)")
        return text
    }

    func windowIds(session: String) throws -> [String] {
        try run(["list-windows", "-t", "=\(session)", "-F", "#{window_id}"])
            .split(separator: "\n").map(String.init)
    }

    func attachControlClient(session: String) throws -> ControlClient {
        try ControlClient(process: process(["-C", "attach-session", "-t", "=\(session)"]))
    }

    func stop() {
        _ = try? run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }

    /// A `tmux -C` client whose output lines are collected as they arrive.
    final class ControlClient: @unchecked Sendable {
        private let process: Process
        private let input = Pipe()
        private let output = Pipe()
        private let arrived = NSCondition()
        private var buffer = Data()
        private var collected: [String] = []

        fileprivate init(process: Process) throws {
            self.process = process
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.append(handle.availableData)
            }
            try process.run()
        }

        var lines: [String] {
            arrived.lock()
            defer { arrived.unlock() }
            return collected
        }

        func write(_ command: String) {
            input.fileHandleForWriting.write(Data((command + "\n").utf8))
        }

        /// Returns the lines once `done` accepts them, or whatever arrived by the deadline.
        /// Wakes on each line tmux sends.
        func waitForLines(timeout: TimeInterval, until done: ([String]) -> Bool) -> [String] {
            let deadline = Date(timeIntervalSinceNow: timeout)
            arrived.lock()
            defer { arrived.unlock() }
            while !done(collected), arrived.wait(until: deadline) {}
            return collected
        }

        func stop() {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        private func append(_ data: Data) {
            guard !data.isEmpty else { return }
            arrived.lock()
            defer {
                arrived.broadcast()
                arrived.unlock()
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                buffer.removeSubrange(buffer.startIndex...newline)
                collected.append(line)
            }
        }
    }
}
