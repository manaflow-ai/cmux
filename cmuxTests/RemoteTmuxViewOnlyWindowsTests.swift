import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A command that names a mirrored window only by its id (`tmux new-window -a -t @12`) lands in
/// whichever session holding that window was used last, and the hidden view session is used every
/// few seconds. Measured on tmux 3.7b. The new window then sits in the view and nowhere else, so it
/// never becomes a tab. It belongs in the real session of the window it was created next to.
@Suite struct RemoteTmuxViewOnlyWindowsTests {
    private typealias Row = RemoteTmuxLinkedWorkspaceModel.WindowRow
    private let view = "cmux-view-v1-owner-hash"

    /// `main` holds @1 @2 @3 at 0 1 2; the view holds its placeholder @0 and links all three.
    private var baseRows: [Row] {
        [
            Row(sessionName: "main", windowId: "@1", windowIndex: 0),
            Row(sessionName: "main", windowId: "@2", windowIndex: 1),
            Row(sessionName: "main", windowId: "@3", windowIndex: 2),
            Row(sessionName: view, windowId: "@0", windowIndex: 0),
            Row(sessionName: view, windowId: "@1", windowIndex: 1),
            Row(sessionName: view, windowId: "@2", windowIndex: 2),
            Row(sessionName: view, windowId: "@3", windowIndex: 3),
        ]
    }

    private func adoptions(_ rows: [Row], owned: Set<String> = ["@1", "@2", "@3"]) -> [RemoteTmuxViewOnlyWindows.Adoption] {
        RemoteTmuxViewOnlyWindows.adoptions(
            rows: rows, viewSessionName: view, excludedSessions: [view],
            placeholderWindowId: "@0", cmuxOwnedWindowIds: owned)
    }

    @Test func aWindowCreatedNextToAMirroredWindowJoinsThatWindowsSession() {
        // `new-window -a -t @2` resolved to the view: the new @9 sits right after @2 there only.
        var rows = baseRows.filter { $0.sessionName != view || $0.windowIndex < 3 }
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 3))
        rows.append(Row(sessionName: view, windowId: "@3", windowIndex: 4))
        #expect(adoptions(rows) == [.init(windowId: "@9", sessionName: "main", afterWindowId: "@2")])
    }

    @Test func aWindowCmuxLinkedWhoseSessionIsGoneIsNotAdopted() {
        // @3's home session was killed; the view's copy is cmux's own and gets cleaned up instead.
        let rows = baseRows.filter { !($0.sessionName == "main" && $0.windowId == "@3") }
        #expect(adoptions(rows).isEmpty)
    }

    @Test func thePlaceholderIsNeverAdopted() {
        #expect(adoptions(baseRows).isEmpty)
    }

    @Test func aWindowWithNoMirroredWindowBeforeItStaysWhereItIs() {
        var rows = baseRows.map { row -> Row in
            row.sessionName == view && row.windowIndex > 0
                ? Row(sessionName: view, windowId: row.windowId, windowIndex: row.windowIndex + 1)
                : row
        }
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 1))
        #expect(adoptions(rows).isEmpty, "there is no neighbour to say which session it belongs to")
    }

    @Test func aWindowAlreadyInARealSessionIsLeftAlone() {
        var rows = baseRows
        rows.append(Row(sessionName: "other", windowId: "@9", windowIndex: 0))
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 4))
        #expect(adoptions(rows, owned: ["@1", "@2", "@3", "@9"]).isEmpty)
    }

    @Test func viewOnlyNeighboursAreSkippedToTheNearestMirroredWindow() {
        var rows = baseRows
        rows.append(Row(sessionName: view, windowId: "@8", windowIndex: 4))
        rows.append(Row(sessionName: view, windowId: "@9", windowIndex: 5))
        // @9 follows @8, not @3, or the two would land in main reversed.
        #expect(adoptions(rows) == [
            .init(windowId: "@8", sessionName: "main", afterWindowId: "@3"),
            .init(windowId: "@9", sessionName: "main", afterWindowId: "@8"),
        ])
    }

    /// Two windows created one after another next to the same mirrored window, and a third next
    /// to a later one, must land in the real session in the order they sit in the view. Run
    /// against a real tmux, since `link-window -a` shifts every later index in the session.
    @Test(.enabled(if: ViewOnlyTmuxServer.binary != nil))
    func adoptionsKeepTheViewsOrderInARealTmux() throws {
        let tmux = try ViewOnlyTmuxServer()
        defer { tmux.stop() }
        func newWindow(_ arguments: [String]) throws -> String {
            try tmux.run(arguments + ["-P", "-F", "#{window_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let a = try newWindow(["new-session", "-d", "-s", "main"])
        let b = try newWindow(["new-window", "-d", "-t", "=main:"])
        let c = try newWindow(["new-window", "-d", "-t", "=main:"])
        let placeholder = try newWindow(["new-session", "-d", "-s", "view"])
        for id in [a, b, c] { try tmux.run(["link-window", "-d", "-s", id, "-t", "=view:"]) }
        let x = try newWindow(["new-window", "-d", "-a", "-t", "=view:\(b)"])
        let y = try newWindow(["new-window", "-d", "-a", "-t", "=view:\(x)"])
        let z = try newWindow(["new-window", "-d", "-a", "-t", "=view:\(c)"])
        #expect(try tmux.windowIds(session: "view") == [placeholder, a, b, x, y, c, z])

        let rows = RemoteTmuxLinkedWorkspaceModel.parseRows(
            try tmux.run(["list-windows", "-a", "-F", RemoteTmuxLinkedWorkspaceModel.listFormat]))
        let adoptions = RemoteTmuxViewOnlyWindows.adoptions(
            rows: rows, viewSessionName: "view", excludedSessions: ["view"],
            placeholderWindowId: placeholder, cmuxOwnedWindowIds: [a, b, c])
        #expect(adoptions.count == 3)
        let commands = tmux.directory.appendingPathComponent("adopt.conf")
        try RemoteTmuxViewOnlyWindows.linkCommands(adoptions, viewSessionName: "view").map { $0.joined(separator: " ; ") }
            .joined(separator: "\n")
            .write(to: commands, atomically: true, encoding: .utf8)
        try tmux.run(["source-file", commands.path])

        #expect(try tmux.windowIds(session: "main") == [a, b, x, y, c, z])
        // Each link carries its mark in the same command sequence, so an adopted window is
        // known as cmux's on the next bringup.
        for id in [x, y, z] { #expect(try tmux.windowMark(id) == "1", "\(id) has no mark") }
    }

    /// The mark rides in the same tmux command sequence as the link, and tmux skips the rest of
    /// a sequence once a command fails. A link tmux refuses therefore leaves its window
    /// unmarked, free to be adopted later, instead of marked as cmux's and destroyed by the
    /// next reconcile's `unlink-window -k`.
    @Test(.enabled(if: ViewOnlyTmuxServer.binary != nil))
    func aLinkTmuxRefusesLeavesItsWindowUnmarkedInARealTmux() throws {
        let tmux = try ViewOnlyTmuxServer()
        defer { tmux.stop() }
        _ = try tmux.run(["new-session", "-d", "-s", "view"])
        let x = try tmux.run(["new-window", "-d", "-t", "=view:", "-P", "-F", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = try #require(RemoteTmuxViewOnlyWindows.linkCommands([
            .init(windowId: x, sessionName: "gone", afterWindowId: "@999"),
        ], viewSessionName: "view").first)
        let file = tmux.directory.appendingPathComponent("refused.conf")
        try command.joined(separator: " ; ").write(to: file, atomically: true, encoding: .utf8)
        tmux.runIgnoringFailure(["source-file", file.path])

        #expect(try tmux.windowMark(x) == "")
        #expect(try tmux.windowIds(session: "view").contains(x))
    }

    /// tmux reads a target that starts with `$` as a session id, so `=$home:@1` finds nothing and
    /// a window next to a window of a session named `$home` could never be adopted. The adoption
    /// names the session by its id instead.
    @Test(.enabled(if: ViewOnlyTmuxServer.binary != nil))
    func aWindowJoinsASessionWhoseNameStartsWithDollarInARealTmux() throws {
        let tmux = try ViewOnlyTmuxServer()
        defer { tmux.stop() }
        func newWindow(_ arguments: [String]) throws -> String {
            try tmux.run(arguments + ["-P", "-F", "#{window_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let home = try tmux.run(["new-session", "-d", "-s", "$home", "-P", "-F", "#{session_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let a = try tmux.run(["list-windows", "-t", home, "-F", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = try newWindow(["new-session", "-d", "-s", "view"])
        try tmux.run(["link-window", "-d", "-s", a, "-t", "=view:"])
        let x = try newWindow(["new-window", "-d", "-a", "-t", "=view:\(a)"])

        let rows = RemoteTmuxLinkedWorkspaceModel.parseRows(
            try tmux.run(["list-windows", "-a", "-F", RemoteTmuxLinkedWorkspaceModel.listFormat]))
        let adoptions = RemoteTmuxViewOnlyWindows.adoptions(
            rows: rows, viewSessionName: "view", excludedSessions: ["view"],
            placeholderWindowId: placeholder, cmuxOwnedWindowIds: [a])
        #expect(adoptions.count == 1)
        let file = tmux.directory.appendingPathComponent("dollar.conf")
        try RemoteTmuxViewOnlyWindows.linkCommands(adoptions, viewSessionName: "view").map { $0.joined(separator: " ; ") }
            .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        tmux.runIgnoringFailure(["source-file", file.path])

        let homeWindows = try tmux.run(["list-windows", "-t", home, "-F", "#{window_id}"])
            .split(separator: "\n").map(String.init)
        #expect(homeWindows == [a, x])
    }

    /// A window cmux unlinks from the view loses its mark. The mark is a window option and
    /// outlives the link, so a window linked into the view again by hand would otherwise read as
    /// cmux's, and be destroyed with `unlink-window -k` once its real session ended.
    @Test(.enabled(if: ViewOnlyTmuxServer.binary != nil))
    func aWindowUnlinkedFromTheViewLosesItsMarkInARealTmux() throws {
        let tmux = try ViewOnlyTmuxServer()
        defer { tmux.stop() }
        let a = try tmux.run(["new-session", "-d", "-s", "main", "-P", "-F", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try tmux.run(["new-session", "-d", "-s", "view"])
        try tmux.run(["link-window", "-d", "-s", a, "-t", "=view:"])
        let index = try tmux.run(["display-message", "-p", "-t", "=view:\(a)", "#{window_index}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try tmux.run(["set-option", "-w", "-t", a, RemoteTmuxViewSession.optLinked(viewSessionName: "view"), "1"])

        let commands = RemoteTmuxViewConnection.unlinkFromViewCommands(
            windowId: a, viewSessionName: "view", windowIndex: try #require(Int(index)))
        let file = tmux.directory.appendingPathComponent("unlink.conf")
        try commands.joined(separator: " ; ").write(to: file, atomically: true, encoding: .utf8)
        try tmux.run(["source-file", file.path])

        #expect(try tmux.windowIds(session: "main") == [a])
        #expect(try !tmux.windowIds(session: "view").contains(a))
        #expect(try tmux.windowMark(a) == "")
    }

    /// Two cmux installs mirroring one host each have a view, and a window can sit in both. The
    /// mark is a window option, so one name for every view would let one view's cleanup clear the
    /// mark the other view's copy relies on, and that view's next bringup would adopt its copy of
    /// a killed session's window into a live session. Each view's mark has its own name.
    @Test(.enabled(if: ViewOnlyTmuxServer.binary != nil))
    func oneViewsUnlinkKeepsAnotherViewsMarkInARealTmux() throws {
        let tmux = try ViewOnlyTmuxServer()
        defer { tmux.stop() }
        let a = try tmux.run(["new-session", "-d", "-s", "main", "-P", "-F", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for viewName in ["view", "other"] {
            _ = try tmux.run(["new-session", "-d", "-s", viewName])
            let link = RemoteTmuxViewSession.linkAndMark(
                "link-window -d -s \(a) -t '=\(viewName):'", windowId: a, viewSessionName: viewName)
            let file = tmux.directory.appendingPathComponent("link-\(viewName).conf")
            try link.joined(separator: " ; ").write(to: file, atomically: true, encoding: .utf8)
            try tmux.run(["source-file", file.path])
        }
        let index = try tmux.run(["display-message", "-p", "-t", "=view:\(a)", "#{window_index}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let commands = RemoteTmuxViewConnection.unlinkFromViewCommands(
            windowId: a, viewSessionName: "view", windowIndex: try #require(Int(index)))
        let file = tmux.directory.appendingPathComponent("unlink.conf")
        try commands.joined(separator: " ; ").write(to: file, atomically: true, encoding: .utf8)
        try tmux.run(["source-file", file.path])

        #expect(try tmux.windowMark(a, viewSessionName: "view") == "")
        #expect(try tmux.windowMark(a, viewSessionName: "other") == "1")
        let rows = try tmux.run([
            "list-windows", "-t", "=other", "-F",
            RemoteTmuxViewConnection.bringupListFormat(viewSessionName: "other"),
        ]).split(separator: "\n").map(String.init)
        #expect(RemoteTmuxViewConnection.readBringupRows(rows).adopted.contains(a))
    }

    /// The bringup reads the view's settled flag through a window format, where tmux falls back
    /// from window options to the session's.
    @Test(.enabled(if: ViewOnlyTmuxServer.binary != nil))
    func theBringupFormatReadsTheViewsFlagAndEachMarkInARealTmux() throws {
        let tmux = try ViewOnlyTmuxServer()
        defer { tmux.stop() }
        let placeholder = try tmux.run(["new-session", "-d", "-s", "view", "-P", "-F", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let marked = try tmux.run(["new-window", "-d", "-t", "=view:", "-P", "-F", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try tmux.run(["set-option", "-w", "-t", marked, RemoteTmuxViewSession.optLinked(viewSessionName: "view"), "1"])
        let format = RemoteTmuxViewConnection.bringupListFormat(viewSessionName: "view")
        let before = try tmux.run(["list-windows", "-t", "=view", "-F", format]).split(separator: "\n").map(String.init)
        #expect(RemoteTmuxViewConnection.readBringupRows(before).marksSettled == false)

        _ = try tmux.run(["set-option", "-t", "view", RemoteTmuxViewSession.optMarksSettled, "1"])
        let after = try tmux.run(["list-windows", "-t", "=view", "-F", format]).split(separator: "\n").map(String.init)
        let read = RemoteTmuxViewConnection.readBringupRows(after)
        #expect(read.marksSettled)
        #expect(read.placeholder == placeholder)
        #expect(read.adopted == [marked])
        #expect(read.markPlaceholder)

        _ = try tmux.run(["set-option", "-w", "-t", placeholder, RemoteTmuxViewSession.optPlaceholder, "1"])
        let placed = try tmux.run(["list-windows", "-t", "=view", "-F", format]).split(separator: "\n").map(String.init)
        #expect(!RemoteTmuxViewConnection.readBringupRows(placed).markPlaceholder)
        #expect(RemoteTmuxViewConnection.readBringupRows(placed).placeholder == placeholder)
    }

    /// Owning an adopted window waits for tmux's answer to its link, not for the write to queue.
    @Test @MainActor func anAdoptedWindowIsOwnedOnlyOnceTmuxAcceptsItsLink() {
        var completions: [(Bool) -> Void] = []
        var sent: [[String]] = []
        var owned: [String] = []
        var failed: [String] = []
        RemoteTmuxViewConnection.adopt(
            [
                .init(windowId: "@7", sessionName: "main", afterWindowId: "@1"),
                .init(windowId: "@8", sessionName: "main", afterWindowId: "@7"),
            ],
            viewSessionName: view,
            send: { command, completion in
                sent.append(command)
                completions.append(completion)
                return true
            },
            onLinked: { owned.append($0) },
            onFailed: { failed.append($0) }
        )
        #expect(sent.count == 2)
        #expect(owned.isEmpty, "a queued link is not a link yet")
        completions[0](true)
        completions[1](false)
        #expect(owned == ["@7"])
        #expect(failed == ["@8"], "a refused link is reported, so the view can try again")
        #expect((1...RemoteTmuxViewConnection.maxAdoptionRetries).allSatisfy {
            RemoteTmuxViewConnection.shouldRetryAdoption(failures: $0)
        })
        #expect(!RemoteTmuxViewConnection.shouldRetryAdoption(
            failures: RemoteTmuxViewConnection.maxAdoptionRetries + 1))
    }

    /// The writes that link or mark view windows, each sent on the view's control stream.
    enum ViewWrite: CaseIterable {
        case adoption, link, twoMarksAndTheSettledFlag

        /// How many commands the write's sequence holds, so how many blocks tmux answers it with.
        var commandCount: Int { self == .twoMarksAndTheSettledFlag ? 3 : 2 }
    }

    /// Replies are matched to commands by position, and tmux answers every command of an `a ; b`
    /// sequence with its own block. A link and its mark that reserved one reply slot left the
    /// mark's reply to whatever was sent next, and every reply after that went to the command
    /// before it: here a new window would get no id.
    @Test(arguments: ViewWrite.allCases) @MainActor
    func aViewWriteLeavesTheNextCommandItsOwnReply(_ write: ViewWrite) {
        let stream = AttachedControlStream()
        defer { stream.close() }
        let connection = stream.connection
        var linked: [String] = []
        switch write {
        case .adoption:
            RemoteTmuxViewConnection.adopt(
                [.init(windowId: "@7", sessionName: "main", afterWindowId: "@1")],
                viewSessionName: view,
                on: connection,
                onLinked: { linked.append($0) }
            )
        case .link:
            #expect(RemoteTmuxViewConnection.linkIntoView("@7", viewSessionName: view, on: connection))
        case .twoMarksAndTheSettledFlag:
            #expect(RemoteTmuxViewConnection.settleMarks(["@7", "@8"], viewSessionName: view, on: connection))
        }
        var newWindowId: Int?
        var newWindowAnswered = false
        #expect(connection.sendNewWindow("new-window -P -F '#{window_id}'") {
            newWindowAnswered = true
            newWindowId = $0
        })

        for _ in 0..<write.commandCount { stream.reply([]) }
        stream.reply(["@9"])

        #expect(newWindowAnswered)
        #expect(newWindowId == 9, "the new window got the reply meant for the \(write)")
        if write == .adoption { #expect(linked == ["@7"]) }
    }

    /// A window the reconcile links into the view is cmux's once tmux carries out the link, not
    /// when it is queued. Owned on a refused link, it would be unlinked with `-k`, which destroys
    /// it, once it later sat in the view alone.
    @Test @MainActor func aLinkIntoTheViewReportsTmuxsAnswer() {
        let stream = AttachedControlStream()
        defer { stream.close() }
        var answers: [Bool] = []
        #expect(RemoteTmuxViewConnection.linkIntoView("@7", viewSessionName: view, on: stream.connection) {
            answers.append($0)
        })
        #expect(RemoteTmuxViewConnection.linkIntoView("@8", viewSessionName: view, on: stream.connection) {
            answers.append($0)
        })
        #expect(answers.isEmpty, "a queued link is not a link yet")
        stream.reply(["can't find window: @7"], isError: true)
        stream.reply([])
        stream.reply([])
        #expect(answers == [false, true])
    }

    /// tmux runs nothing after a command that fails, so a refused link gets one block and its
    /// mark none. The window stays unowned and the next command still gets its own reply.
    @Test @MainActor func aRefusedAdoptionLeavesTheNextCommandItsOwnReply() {
        let stream = AttachedControlStream()
        defer { stream.close() }
        let connection = stream.connection
        var linked: [String] = []
        RemoteTmuxViewConnection.adopt(
            [.init(windowId: "@7", sessionName: "gone", afterWindowId: "@1")],
            viewSessionName: view,
            on: connection,
            onLinked: { linked.append($0) }
        )
        var newWindowId: Int?
        #expect(connection.sendNewWindow("new-window -P -F '#{window_id}'") { newWindowId = $0 })

        stream.reply(["can't find session: gone"], isError: true)
        stream.reply(["@9"])

        #expect(linked.isEmpty)
        #expect(newWindowId == 9)
    }

    /// The bringup reads which view windows cmux linked from the mark it leaves on each window,
    /// not from the window being in the view. A window that is in the view alone and carries no
    /// mark was created there, and must stay free to be adopted; marking it ours would get it
    /// unlinked with `-k`, which destroys it.
    @Test func theBringupOwnsOnlyWindowsCmuxLinked() {
        let read = RemoteTmuxViewConnection.readBringupRows(["@0 0  1", "@1 1  1", "@9 0  1", "@5 0 1 1"])
        #expect(read.marksSettled)
        #expect(read.placeholder == "@0")
        #expect(read.adopted == ["@1", "@5"])
        #expect(read.toMark.isEmpty)
    }

    /// A view an older cmux left behind has no marks. A window in it alone may be a copy that
    /// cmux linked before its session was killed, or one somebody created in the view. Reconcile
    /// unlinks a dead copy with `-k`, which destroys a window whose only link is the view, so the
    /// bringup claims only the windows that are also in a real session, and marks them so later
    /// bringups can use the marks. The same read follows a settle write tmux refused.
    @Test func aViewWithoutMarksClaimsOnlyWindowsLinkedElsewhere() {
        let read = RemoteTmuxViewConnection.readBringupRows(["@0 0  ", "@1 1  ", "@9 0  "])
        #expect(!read.marksSettled)
        #expect(read.placeholder == "@0")
        #expect(read.adopted == ["@1"])
        #expect(read.toMark == ["@1"])
    }

    /// The placeholder carries its own mark, so a bringup finds it wherever it sits. Read by
    /// position, a window created in the view ahead of it would be taken for the placeholder,
    /// and the real one, unmarked and unlinked, would be adopted into a session as a tab.
    @Test func thePlaceholderIsFoundByItsMarkWhereverItSits() {
        let rows = ["@1 1 1 1 ", "@9 0  1 ", "@0 0  1 1"]
        let read = RemoteTmuxViewConnection.readBringupRows(rows)
        #expect(read.placeholder == "@0")
        #expect(read.adopted == ["@1"])
        #expect(!read.markPlaceholder)
        #expect(RemoteTmuxViewConnection.readBringupRows(["@0 0  1 ", "@1 1 1 1 "]).markPlaceholder,
                "a view whose placeholder has no mark yet gets one")
    }
}

/// A tmux server on its own socket, so nothing here can reach a server the user runs.
private final class ViewOnlyTmuxServer {
    static let binary: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    let directory: URL
    private var socket: String { directory.appendingPathComponent("s").path }

    init() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-viewonly-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(Self.binary))
        process.arguments = ["-S", socket, "-f", "/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment["TMUX_TMPDIR"] = directory.path
        process.environment = environment
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

    /// Runs a command that is expected to fail.
    func runIgnoringFailure(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binary ?? "/usr/bin/false")
        process.arguments = ["-S", socket, "-f", "/dev/null"] + arguments
        process.environment = ["TMUX_TMPDIR": directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    func windowMark(_ windowId: String, viewSessionName: String = "view") throws -> String {
        try run(["display-message", "-p", "-t", windowId,
                 "#{\(RemoteTmuxViewSession.optLinked(viewSessionName: viewSessionName))}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func windowIds(session: String) throws -> [String] {
        try run(["list-windows", "-t", "=\(session)", "-F", "#{window_id}"])
            .split(separator: "\n").map(String.init)
    }

    func stop() {
        _ = try? run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A control connection past its attach, writing to a pipe, so the test can answer its commands.
@MainActor
private struct AttachedControlStream {
    let connection: RemoteTmuxControlConnection
    let writer: RemoteTmuxControlPipeWriter
    let pipe: Pipe

    init() {
        connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "view-only-windows.test"),
            sessionName: "work"
        )
        pipe = Pipe()
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-view-only-windows-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
        // Answer whatever the attach sent next (the window list, and any subscription), so the
        // test's own commands start from an empty queue.
        while !connection.pendingCommandKindsForTesting.isEmpty {
            reply([])
        }
    }

    /// Answers the oldest command still waiting for a reply.
    func reply(_ lines: [String], isError: Bool = false) {
        connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: lines, isError: isError))
    }

    func close() {
        connection.stop()
        writer.close()
        try? pipe.fileHandleForReading.close()
    }
}
