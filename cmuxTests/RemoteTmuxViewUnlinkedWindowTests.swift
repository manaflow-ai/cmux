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

    /// cmux links a window and marks it with a window option; the next bringup reads the mark
    /// to know the window is cmux's. If the mark write fails and the window's session dies while
    /// the stream is down, the window is left in the view alone and unmarked. The bringup must
    /// still treat it as cmux's and destroy it, or it lingers in the view for good.
    @Test func aLinkWhoseMarkFailedIsDestroyedWhenItsSessionDiesDuringAnOutage() async {
        let host = ScriptedViewHost(sessions: [
            .init(name: "work", id: 1, windowIds: ["@1", "@2"]),
            .init(name: "keep", id: 2, windowIds: ["@5"]),
        ], prelinked: false)
        host.failingMarks = ["@2"]
        defer { host.close() }
        await host.connect()
        #expect(host.linkedIntoView.sorted() == ["@1", "@2", "@5"])
        #expect(host.marked == ["@1", "@5"], "the mark on @2 was refused")

        await host.reattach { host.sessions.removeAll { $0.name == "work" } }

        #expect(host.linkedIntoView == ["@5"], "both of the dead session's windows are destroyed")
    }

    /// The same outage, but the mark is refused only once. The bringup writes it again before it
    /// reads the view, so tmux holds the mark again and later bringups can rely on it.
    @Test func aRefusedMarkIsWrittenAgainBeforeTheBringupReadsTheView() async {
        let host = ScriptedViewHost(sessions: [
            .init(name: "work", id: 1, windowIds: ["@1", "@2"]),
            .init(name: "keep", id: 2, windowIds: ["@5"]),
        ], prelinked: false)
        host.failingMarksOnce = ["@2"]
        defer { host.close() }
        await host.connect()
        #expect(host.marked == ["@1", "@5"])

        await host.reattach { host.sessions.removeAll { $0.name == "work" } }

        #expect(host.markWrites["@2"] == 2, "the refused mark is written again on the next bringup")
        #expect(host.linkedIntoView == ["@5"])
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

    /// This stream is attached to the view session, so a real answer to `list-sessions` names
    /// it and a real answer to `list-windows -a` lists its windows. Replies are matched to
    /// commands by position, and one that lands on the wrong command reads as a host with no
    /// sessions or no windows. That must not close anything: seen live, one misplaced reply
    /// closed every workspace for the host while the connection was still up.
    @Test(arguments: ["list-sessions", "list-windows -a"])
    func listReplyWithoutTheViewSessionClosesNothing(_ misplaced: String) async {
        let host = ScriptedViewHost(sessions: [.init(name: "work", id: 1, windowIds: ["@1"])])
        defer { host.close() }
        await host.connect()
        #expect(host.view.workspaces.map(\.sessionName) == ["work"])
        var workspaceChanges = 0
        host.view.onWorkspacesChanged = { workspaceChanges += 1 }

        // The empty reply of some other command, where the list should have been.
        host.emptyReplyOnce = misplaced
        host.feed("%sessions-changed\n")
        await host.settle()

        #expect(host.emptyReplyOnce == nil, "the reconcile must have sent \(misplaced)")
        #expect(
            host.view.workspaces.map(\.sessionName) == ["work"],
            "a reply that cannot be the answer to \(misplaced) closed the host's workspaces"
        )
        #expect(workspaceChanges == 0)
        #expect(
            host.connection.connectionState == .reconnecting,
            "the replies are out of step with the commands, and only a fresh stream puts them back"
        )
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
    /// The next command starting with this text is answered with an empty block, once.
    var emptyReplyOnce: String?
    /// Windows whose mark write tmux answers with `%error`, every time or only the first time.
    var failingMarks: Set<String> = []
    var failingMarksOnce: Set<String> = []
    /// Windows that carry this view's mark, and how many mark writes each received.
    private(set) var marked: Set<String> = []
    private(set) var markWrites: [String: Int] = [:]
    /// Windows linked into the view after its placeholder, in link order.
    private(set) var linkedIntoView: [String] = []
    /// Each linked window's index in the view. tmux keeps indices when a window leaves, so an
    /// unlink must not shift the windows after it.
    private var viewIndex: [String: Int] = [:]
    /// Every command the connection wrote, in send order.
    private(set) var sentCommands: [String] = []

    private let ownerId = "unlinked-window-test-owner"
    private let viewSessionId = 99
    private let placeholderWindowId = "@0"
    private var pipe = Pipe()
    private var writer: RemoteTmuxControlPipeWriter
    private var parser = RemoteTmuxControlStreamParser()
    private var unreadBytes: [UInt8] = []
    private var answeredCount = 0
    private var observerToken: RemoteTmuxControlConnection.ObserverToken?

    init(sessions: [Session], prelinked: Bool = true) {
        self.sessions = sessions
        let host = RemoteTmuxHost(destination: "user@unlinked-window-test")
        view = RemoteTmuxViewConnection(host: host, ownerId: ownerId)
        connection = RemoteTmuxControlConnection(host: host, sessionName: view.view.sessionName)
        connection.isSharedViewStream = true
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-unlinked-view-test",
            maxPendingBytes: 1 << 20,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        view.connection = connection
        // The same wiring `RemoteTmuxViewConnection.start()` installs on the stream it opens.
        observerToken = connection.addObserver(
            onTopologyChanged: { [weak view] in view?.requestReconcile() },
            onConnectionStateChanged: { [weak view] state in view?.streamStateChanged(state) }
        )
        linkedIntoView = prelinked ? sessions.flatMap(\.windowIds) : []
    }

    /// Drops the stream, runs `outage` against the server model, and attaches a fresh stream,
    /// the way a reconnect does: the view sees a new client and runs its bringup again.
    func reattach(during outage: () -> Void) async {
        connection.beginReconnecting()
        outage()
        pipe = Pipe()
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting, label: "remote-tmux-unlinked-view-test", maxPendingBytes: 1 << 20,
            onFailure: {})
        connection.installStdinWriterForTesting(writer)
        parser = RemoteTmuxControlStreamParser()
        unreadBytes = []
        sentCommands = []
        answeredCount = 0
        await connect()
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

    /// Answers queued commands until the view is quiet: no command waiting for a reply and no
    /// reconcile running or queued. A notification that schedules nothing is quiet at once.
    func settle() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            // A notification schedules its reconcile as a main-actor task. A task enqueued after
            // it runs once that one has started, so past this line `isReconciling` is current.
            await Task { @MainActor in }.value
            answerPendingCommands()
            guard isQuiet else { continue }
            // A reconcile that just finished may have scheduled the one queued behind it.
            await Task { @MainActor in }.value
            if isQuiet { return }
        }
        Issue.record("the view never went quiet: pending=\(connection.pendingCommandKindsForTesting) reconciling=\(view.isReconciling)")
    }

    private var isQuiet: Bool {
        connection.pendingCommandKindsForTesting.isEmpty && !view.isReconciling
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
            let refused = refusesMark(command)
            connection.handleMessageForTesting(
                .commandResult(commandNumber: answeredCount + 1, lines: refused ? ["refused"] : reply(to: command),
                               isError: refused)
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

    /// Applies a mark write to the model, or refuses it as scripted.
    private func refusesMark(_ command: String) -> Bool {
        guard command.hasPrefix("set-option -w -t @"),
              command.contains(RemoteTmuxViewConnection.windowMarkOption(viewSessionName: view.view.sessionName)),
              let windowId = command.split(separator: " ").dropFirst(3).first.map(String.init) else { return false }
        markWrites[windowId, default: 0] += 1
        if failingMarks.contains(windowId) { return true }
        if failingMarksOnce.remove(windowId) != nil { return true }
        marked.insert(windowId)
        return false
    }

    private func indexInView(_ windowId: String) -> Int {
        if let index = viewIndex[windowId] { return index }
        let index = (viewIndex.values.max() ?? 0) + 1
        viewIndex[windowId] = index
        return index
    }

    private func reply(to command: String) -> [String] {
        let viewName = view.view.sessionName
        if let prefix = emptyReplyOnce, command.hasPrefix(prefix) {
            emptyReplyOnce = nil
            return []
        }
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
            for windowId in linkedIntoView {
                rows.append("$\(viewSessionId):\(windowId):\(indexInView(windowId)):0:\(viewName)")
            }
            return rows
        }
        if command.hasPrefix("list-windows -t") {
            let inSessions = Set(sessions.flatMap(\.windowIds))
            return ["\(placeholderWindowId) 0 "] + linkedIntoView.map {
                "\($0) \(inSessions.contains($0) ? 1 : 0) \(marked.contains($0) ? "1" : "")"
            }
        }
        if command.hasPrefix("unlink-window -k -t"), let index = command.split(separator: ":").last.flatMap({ Int($0) }),
           let windowId = linkedIntoView.first(where: { indexInView($0) == index }) {
            linkedIntoView.removeAll { $0 == windowId }
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
