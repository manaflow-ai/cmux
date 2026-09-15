import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The multiplexer's one control client is attached to the hidden view session, and every real
/// session's windows are linked into it. A window or session created on the host from outside cmux
/// starts out in a real session only, so tmux tells this client about it with `%unlinked-window-add`
/// and `%sessions-changed` (measured on tmux 3.7b), never `%window-add`. If the view stream ignores
/// those, nothing links the new window and it shows up only when some unrelated event forces a
/// reconcile.
@MainActor
@Suite struct RemoteTmuxViewUnlinkedWindowTests {
    @Test func unlinkedWindowAddOnTheViewStreamLinksTheNewWindow() async {
        let host = ScriptedViewHost(sessions: [.init(name: "work", id: 1, windowIds: ["@1"])])
        defer { host.close() }
        await host.connect()
        #expect(host.linkedIntoView == ["@1"])
        #expect(host.view.workspaces.map(\.windowIds) == [["@1"]])
        let reconcilesBefore = host.reconcileCount

        // `new-window -t work` run on the host, outside cmux.
        host.sessions[0].windowIds.append("@7")
        host.feed("%unlinked-window-add @7\n")
        await host.settle()

        #expect(host.reconcileCount > reconcilesBefore, "the view must re-read the server after %unlinked-window-add")
        #expect(host.linkedIntoView == ["@1", "@7"], "the new window must be linked into the view")
        #expect(host.view.workspaces.map(\.sessionName) == ["work"])
        #expect(host.view.workspaces.map(\.windowIds) == [["@1", "@7"]], "the new window must surface as a tab")
    }

    @Test func sessionsChangedOnTheViewStreamSurfacesTheNewSession() async {
        let host = ScriptedViewHost(sessions: [.init(name: "work", id: 1, windowIds: ["@1"])])
        defer { host.close() }
        await host.connect()
        let reconcilesBefore = host.reconcileCount

        // `new-session -d -s fresh` run on the host. Only %sessions-changed is fed, so this proves
        // that notification alone is enough.
        host.sessions.append(.init(name: "fresh", id: 4, windowIds: ["@9"]))
        host.feed("%sessions-changed\n")
        await host.settle()

        #expect(host.reconcileCount > reconcilesBefore, "the view must re-read the server after %sessions-changed")
        #expect(host.linkedIntoView == ["@1", "@9"], "the new session's window must be linked into the view")
        #expect(host.view.workspaces.map(\.sessionName) == ["fresh", "work"], "the new session must surface as a workspace")
        #expect(host.view.workspaces.map(\.windowIds) == [["@9"], ["@1"]])
    }

    /// tmux sends `%unlinked-window-renamed` for every automatic rename in a window the client's
    /// session does not hold, so it arrives each time a command starts in such a window. A mirrored
    /// window is linked into the view, and its renames arrive as `%window-renamed`. Reconciling on the
    /// unlinked form would re-list the whole server for nothing.
    @Test func unlinkedRenameOnTheViewStreamDoesNotReconcile() async {
        let host = ScriptedViewHost(sessions: [.init(name: "work", id: 1, windowIds: ["@1"])])
        defer { host.close() }
        await host.connect()
        let reconcilesBefore = host.reconcileCount

        host.feed("%unlinked-window-renamed @2 zsh\n")
        await host.settle()

        #expect(host.reconcileCount == reconcilesBefore)
        #expect(host.linkedIntoView == ["@1"])
    }

    /// A per-session client is attached to the real session, so its own windows still arrive as
    /// `%window-add`. The unlinked notifications and `%sessions-changed` are about other sessions and
    /// must change nothing there.
    @Test func perSessionStreamIgnoresUnlinkedNotifications() {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@unlinked-per-session"), sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-unlinked-per-session-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        defer {
            connection.stop()
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
        var parser = RemoteTmuxControlStreamParser()
        for message in parser.feed(Data("\u{1b}P1000p%begin 1 1 0\n%end 1 1 0\n".utf8)) {
            connection.handleMessageForTesting(message)
        }
        let pendingBefore = connection.pendingCommandKindsForTesting
        var topologyNotifies = 0
        let token = connection.addObserver(onTopologyChanged: { topologyNotifies += 1 })
        defer { connection.removeObserver(token) }

        let stream = "%unlinked-window-add @7\n%unlinked-window-renamed @7 zsh\n%sessions-changed\n"
        for message in parser.feed(Data(stream.utf8)) {
            connection.handleMessageForTesting(message)
        }

        #expect(topologyNotifies == 0)
        #expect(connection.pendingCommandKindsForTesting == pendingBefore)
    }

    @Test func parserReadsUnlinkedWindowNotifications() {
        var parser = RemoteTmuxControlStreamParser()
        let stream = "%unlinked-window-add @7\n%unlinked-window-renamed @7 my window\n%sessions-changed\n"
        #expect(parser.feed(Data(stream.utf8)) == [
            .unlinkedWindowAdd(windowId: 7),
            .unlinkedWindowRenamed(windowId: 7, name: "my window"),
            .sessionsChanged,
        ])
    }
}

/// A scripted tmux server behind a view coordinator's control stream.
///
/// Commands the connection writes are read back from its stdin pipe and answered from a small model
/// of the server's sessions, so the coordinator's real reconcile runs end to end: it lists sessions
/// and windows, plans, and sends `link-window`, which the model applies.
@MainActor
private final class ScriptedViewHost {
    struct Session {
        var name: String
        var id: Int
        var windowIds: [String]
    }

    let view: RemoteTmuxViewConnection
    let connection: RemoteTmuxControlConnection
    var sessions: [Session]
    /// Windows linked into the view after its placeholder, in link order.
    private(set) var linkedIntoView: [String] = []
    /// Every command the connection wrote, in send order.
    private(set) var sentCommands: [String] = []

    private let ownerId = "unlinked-window-test-owner"
    private let viewSessionId = 99
    private let placeholderWindowId = "@0"
    private let pipe = Pipe()
    private let writer: RemoteTmuxControlPipeWriter
    private var parser = RemoteTmuxControlStreamParser()
    private var unreadBytes: [UInt8] = []
    private var answeredCount = 0
    private var observerToken: RemoteTmuxControlConnection.ObserverToken?

    init(sessions: [Session]) {
        self.sessions = sessions
        let host = RemoteTmuxHost(destination: "user@unlinked-window-test")
        view = RemoteTmuxViewConnection(
            host: host, ownerId: ownerId, transport: RemoteTmuxSSHTransport(host: host)
        )
        connection = RemoteTmuxControlConnection(host: host, sessionName: view.view.sessionName)
        connection.isSharedViewStream = true
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-unlinked-view-test",
            maxPendingBytes: 1 << 20,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        view.adoptConnectionForTesting(connection)
        // The same wiring `RemoteTmuxViewConnection.start()` installs on the stream it opens.
        observerToken = connection.addObserver(
            onTopologyChanged: { [weak view] in view?.requestReconcile() },
            onConnectionStateChanged: { [weak view] state in
                if state == .connected { view?.requestReconcile() }
            }
        )
        linkedIntoView = sessions.flatMap(\.windowIds)
    }

    /// How many times the coordinator has read the server's session list.
    var reconcileCount: Int {
        sentCommands.filter { $0.hasPrefix("list-sessions") }.count
    }

    /// Enters control mode, drains the attach block, and lets the first reconcile finish.
    func connect() async {
        feed("\u{1b}P1000p%begin 1 1 0\n%end 1 1 0\n")
        await settle()
    }

    func feed(_ text: String) {
        for message in parser.feed(Data(text.utf8)) {
            connection.handleMessageForTesting(message)
        }
    }

    /// Answers queued commands and yields so the coordinator's reconcile tasks can run. Bounded,
    /// so a notification that schedules nothing ends the wait instead of hanging the test.
    func settle() async {
        for _ in 0..<64 {
            answerPendingCommands()
            await Task.yield()
        }
        answerPendingCommands()
    }

    func close() {
        if let observerToken { connection.removeObserver(observerToken) }
        view.stop()
        writer.close()
        try? pipe.fileHandleForReading.close()
    }

    private func answerPendingCommands() {
        while !connection.pendingCommandKindsForTesting.isEmpty {
            readSentCommands(atLeast: answeredCount + connection.pendingCommandKindsForTesting.count)
            guard answeredCount < sentCommands.count else {
                Issue.record("a queued command was never written: \(connection.pendingCommandKindsForTesting)")
                return
            }
            let command = sentCommands[answeredCount]
            answeredCount += 1
            connection.handleMessageForTesting(
                .commandResult(commandNumber: answeredCount + 1, lines: reply(to: command), isError: false)
            )
        }
    }

    /// Blocks until the writer has flushed `count` commands. Every queued command was enqueued on
    /// the writer before it entered the FIFO, so the bytes are already on their way.
    private func readSentCommands(atLeast count: Int) {
        while sentCommands.count < count {
            let chunk = pipe.fileHandleForReading.availableData
            guard !chunk.isEmpty else { return }
            unreadBytes.append(contentsOf: chunk)
            while let newline = unreadBytes.firstIndex(of: 0x0a) {
                let line = String(decoding: unreadBytes[..<newline], as: UTF8.self)
                unreadBytes.removeSubrange(...newline)
                sentCommands.append(contentsOf: line.components(separatedBy: " ; "))
            }
        }
    }

    private func reply(to command: String) -> [String] {
        let viewName = view.view.sessionName
        if command.hasPrefix("list-sessions") {
            return ["1:\(ownerId):\(RemoteTmuxViewSession.formatVersion):\(viewName)"]
                + sessions.map { ":::\($0.name)" }
        }
        if command.hasPrefix("list-windows -a") {
            var rows: [String] = []
            for session in sessions {
                for (index, windowId) in session.windowIds.enumerated() {
                    rows.append("$\(session.id):\(windowId):\(index):\(index == 0 ? 1 : 0):\(session.name)")
                }
            }
            rows.append("$\(viewSessionId):\(placeholderWindowId):0:1:\(viewName)")
            for (offset, windowId) in linkedIntoView.enumerated() {
                rows.append("$\(viewSessionId):\(windowId):\(offset + 1):0:\(viewName)")
            }
            return rows
        }
        if command.hasPrefix("list-windows -t") {
            return ["\(placeholderWindowId) 0"] + linkedIntoView.map { "\($0) 1" }
        }
        if command.hasPrefix("link-window") {
            let tokens = command.split(separator: " ").map(String.init)
            if let flag = tokens.firstIndex(of: "-s"), flag + 1 < tokens.count,
               !linkedIntoView.contains(tokens[flag + 1]) {
                linkedIntoView.append(tokens[flag + 1])
            }
        }
        return []
    }
}
