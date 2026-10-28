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
        #expect(adoptions(rows) == [.init(windowId: "@9", sessionName: "main", afterWindowIndex: 1)])
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
        #expect(adoptions(rows) == [
            .init(windowId: "@8", sessionName: "main", afterWindowIndex: 2),
            .init(windowId: "@9", sessionName: "main", afterWindowIndex: 2),
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
        try RemoteTmuxViewOnlyWindows.linkCommands(adoptions).joined(separator: "\n")
            .write(to: commands, atomically: true, encoding: .utf8)
        try tmux.run(["source-file", commands.path])

        #expect(try tmux.windowIds(session: "main") == [a, b, x, y, c, z])
    }

    /// The bringup reads which view windows cmux linked from the mark it leaves on each window,
    /// not from the window being in the view. A window that is in the view alone and carries no
    /// mark was created there, and must stay free to be adopted; marking it ours would get it
    /// unlinked with `-k`, which destroys it.
    @Test func theBringupOwnsOnlyWindowsCmuxLinked() {
        let read = RemoteTmuxViewConnection.readBringupRows(["@0 0", "@1 1", "@9 0", "@5 0 1"])
        #expect(read.placeholder == "@0")
        #expect(read.adopted == ["@1", "@5"])
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

    func windowIds(session: String) throws -> [String] {
        try run(["list-windows", "-t", "=\(session)", "-F", "#{window_id}"])
            .split(separator: "\n").map(String.init)
    }

    func stop() {
        _ = try? run(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}
