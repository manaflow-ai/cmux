import AppKit
import CmuxFileSearch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A backend that replays fixed batches, optionally waiting for the test to
/// release it before it finishes.
private final class ReplayFileSearchBackend: FileSearchBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [FileSearchQuery] = []
    private let batches: [[FileSearchFileMatches]]
    private let completion: FileSearchCompletion
    private let gate: AsyncStream<Void>?
    private let gateContinuation: AsyncStream<Void>.Continuation?

    init(batches: [[FileSearchFileMatches]], completion: FileSearchCompletion = .completed, gated: Bool = false) {
        self.batches = batches
        self.completion = completion
        if gated {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            gate = stream
            gateContinuation = continuation
        } else {
            gate = nil
            gateContinuation = nil
        }
    }

    var receivedQueries: [FileSearchQuery] {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    func release() {
        gateContinuation?.yield()
    }

    func search(query: FileSearchQuery, rootPath: String, matchLimit: Int, sink: FileSearchBatchMailbox) async -> FileSearchCompletion {
        lock.lock()
        queries.append(query)
        lock.unlock()
        for batch in batches { sink.send(batch) }
        if let gate {
            for await _ in gate { break }
        }
        return completion
    }
}

private func matches(_ path: String, lines: [Int]) -> FileSearchFileMatches {
    FileSearchFileMatches(path: path, matches: lines.map {
        FileSearchMatch(lineNumber: $0, column: 5, length: 6, preview: "let needle", previewMatchRange: 4..<10)
    })
}

@MainActor
@Suite("Find panel", .serialized)
struct FileSearchPanelTests {
    private struct Timeout: Error {}

    private func waitUntil(_ description: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for \(description)")
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private struct Fixture {
        let store: FileExplorerStore
        let container: FileExplorerContainerView
        let backend: ReplayFileSearchBackend
        var panel: FileSearchPanelView { container.findPanel }
    }

    private func makeFixture(
        backend: ReplayFileSearchBackend,
        root: String = "/tmp/cmux-find-panel",
        onOpen: @escaping (String) -> Void = { _ in }
    ) -> Fixture {
        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider(), reloadIfAvailable: false)
        store.setWorkspaceRootIdentity(UUID())
        store.setRootPath(root)
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: onOpen)
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .find) {
            let session = FileSearchSession()
            session.backendOverride = backend
            return session
        }
        container.updateHeader(store: store)
        container.updatePresentation(.find)
        return Fixture(store: store, container: container, backend: backend)
    }

    private func type(_ text: String, into panel: FileSearchPanelView) {
        panel.queryBar.queryField.stringValue = text
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.queryBar.queryField))
    }

    @Test("A typing burst runs one search for the final text")
    func typingBurstIsDebounced() async throws {
        let backend = ReplayFileSearchBackend(batches: [[matches("/tmp/cmux-find-panel/a.swift", lines: [1])]])
        let fixture = makeFixture(backend: backend)
        for text in ["p", "pr", "pri", "priv", "priva", "privat", "private"] {
            type(text, into: fixture.panel)
        }
        try await waitUntil("the debounced search") { fixture.panel.session.engine.phase == .finished(.completed) }

        #expect(backend.receivedQueries.map(\.pattern) == ["private"])
        #expect(fixture.panel.statusLabel.stringValue == FileSearchStatusText.summary(results: 1, files: 1))
    }

    @Test("Results group by file with every match as a child row")
    func groupedOutline() async throws {
        let backend = ReplayFileSearchBackend(batches: [
            [matches("/tmp/cmux-find-panel/a.swift", lines: [1, 2])],
            [matches("/tmp/cmux-find-panel/a.swift", lines: [9]), matches("/tmp/cmux-find-panel/b/c.swift", lines: [4])],
        ])
        let fixture = makeFixture(backend: backend)
        type("needle", into: fixture.panel)
        fixture.panel.runSearchNow()
        try await waitUntil("search completion") { fixture.panel.session.engine.phase == .finished(.completed) }

        let outline = fixture.panel.resultsView
        #expect(outline.numberOfRows == 6)
        let fileA = try #require(fixture.panel.item(atRow: 0) as? FileSearchFileNode)
        #expect(fileA.relativePath == "a.swift")
        #expect(fileA.matches.map(\.lineNumber) == [1, 2, 9])
        #expect((fixture.panel.item(atRow: 3) as? FileSearchMatchNode)?.match.lineNumber == 9)
        #expect((fixture.panel.item(atRow: 4) as? FileSearchFileNode)?.relativePath == "b/c.swift")

        fixture.panel.setAllExpanded(false)
        #expect(outline.numberOfRows == 2)
        fixture.panel.setAllExpanded(true)
        #expect(outline.numberOfRows == 6)
    }

    @Test("A content change during a search waits for it, then searches again")
    func contentRevisionDefersRestart() async throws {
        let backend = ReplayFileSearchBackend(batches: [[matches("/tmp/cmux-find-panel/a.swift", lines: [1])]], gated: true)
        let fixture = makeFixture(backend: backend)
        type("needle", into: fixture.panel)
        fixture.panel.runSearchNow()
        try await waitUntil("the first search to start") { backend.receivedQueries.count == 1 }

        fixture.store.reload()
        fixture.container.updateHeader(store: fixture.store)
        #expect(backend.receivedQueries.count == 1, "A content revision must not restart a running search.")

        backend.release()
        try await waitUntil("the deferred refresh") { backend.receivedQueries.count == 2 }
        backend.release()
        try await waitUntil("the refresh to finish") { !fixture.panel.session.engine.isSearching }
        #expect(fixture.panel.session.engine.activeRequest?.contentRevision == fixture.store.contentRevision)
    }

    @Test("Return in the query field opens the selected match")
    func returnOpensSelection() async throws {
        let backend = ReplayFileSearchBackend(batches: [[matches("/tmp/cmux-find-panel/a.swift", lines: [3])]])
        var opened: [String] = []
        let fixture = makeFixture(backend: backend) { opened.append($0) }
        type("needle", into: fixture.panel)
        fixture.panel.runSearchNow()
        try await waitUntil("results") { fixture.panel.session.engine.phase == .finished(.completed) }

        let handled = fixture.panel.control(
            fixture.panel.queryBar.queryField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handled)
        #expect(opened == ["/tmp/cmux-find-panel/a.swift"])
    }

    @Test("F4 walks matches across files and wraps")
    func nextAndPreviousMatch() async throws {
        let backend = ReplayFileSearchBackend(batches: [[
            matches("/tmp/cmux-find-panel/a.swift", lines: [1, 2]),
            matches("/tmp/cmux-find-panel/b.swift", lines: [7]),
        ]])
        var opened: [String] = []
        let fixture = makeFixture(backend: backend) { opened.append($0) }
        type("needle", into: fixture.panel)
        fixture.panel.runSearchNow()
        try await waitUntil("results") { fixture.panel.session.engine.phase == .finished(.completed) }
        let outline = fixture.panel.resultsView

        fixture.panel.navigateMatch(by: 1)
        #expect((fixture.panel.item(atRow: outline.selectedRow) as? FileSearchMatchNode)?.match.lineNumber == 2)
        fixture.panel.navigateMatch(by: 1)
        #expect((fixture.panel.item(atRow: outline.selectedRow) as? FileSearchMatchNode)?.file.relativePath == "b.swift")
        fixture.panel.navigateMatch(by: 1)
        #expect((fixture.panel.item(atRow: outline.selectedRow) as? FileSearchMatchNode)?.match.lineNumber == 1)
        fixture.panel.navigateMatch(by: -1)
        #expect((fixture.panel.item(atRow: outline.selectedRow) as? FileSearchMatchNode)?.file.relativePath == "b.swift")
        #expect(opened.count == 4)
    }

    @Test("Each workspace keeps its own query and results")
    func perWorkspaceSessions() async throws {
        let backend = ReplayFileSearchBackend(batches: [[matches("/tmp/cmux-find-panel/a.swift", lines: [1])]])
        let fixture = makeFixture(backend: backend)
        let firstWorkspace = try #require(fixture.store.workspaceRootIdentity)
        type("alpha", into: fixture.panel)
        fixture.panel.runSearchNow()
        try await waitUntil("first results") { fixture.panel.session.engine.phase == .finished(.completed) }
        let firstSession = fixture.panel.session

        fixture.store.setWorkspaceRootIdentity(UUID())
        fixture.store.setRootPath("/tmp/cmux-find-panel-other")
        fixture.container.updateHeader(store: fixture.store)
        #expect(fixture.panel.session !== firstSession)
        #expect(fixture.panel.queryBar.queryField.stringValue.isEmpty)
        #expect(fixture.panel.resultsView.numberOfRows == 0)

        fixture.store.setWorkspaceRootIdentity(firstWorkspace)
        fixture.store.setRootPath("/tmp/cmux-find-panel")
        fixture.container.updateHeader(store: fixture.store)
        #expect(fixture.panel.session === firstSession)
        #expect(fixture.panel.queryBar.queryField.stringValue == "alpha")
        #expect(fixture.panel.resultsView.numberOfRows == 2)
        #expect(backend.receivedQueries.count == 1, "Returning to a workspace shows its results without searching again.")
    }

    @Test("Up in the query field walks search history and Down returns to the draft")
    func queryHistory() {
        let fixture = makeFixture(backend: ReplayFileSearchBackend(batches: []))
        let panel = fixture.panel
        panel.history = FileSearchHistory(entries: ["older", "newer"])
        type("draft", into: panel)
        let field = panel.queryBar.queryField

        #expect(panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(field.stringValue == "newer")
        _ = panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveUp(_:)))
        #expect(field.stringValue == "older")
        _ = panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        #expect(field.stringValue == "draft")
        #expect(panel.session.query.pattern == "draft")
    }

    @Test("Toggles and glob fields feed the query")
    func togglesFeedQuery() async throws {
        let backend = ReplayFileSearchBackend(batches: [])
        let fixture = makeFixture(backend: backend)
        let panel = fixture.panel
        panel.queryBar.show(
            query: FileSearchQuery(pattern: "x", isCaseSensitive: true, matchesWholeWord: true, isRegex: true,
                                   includePatterns: "src", excludePatterns: "*.min.js", usesIgnoreFiles: false),
            showsDetails: false
        )
        panel.queryDidChange(immediate: true)
        try await waitUntil("the search") { backend.receivedQueries.count == 1 }
        let query = try #require(backend.receivedQueries.first)
        #expect(query.isCaseSensitive && query.matchesWholeWord && query.isRegex && !query.usesIgnoreFiles)
        #expect(query.includePatterns == "src")
        #expect(query.excludePatterns == "*.min.js")
        #expect(!panel.queryBar.includeField.isHiddenOrHasHiddenAncestor, "Details open when globs are set.")
    }

    @Test("An invalid regex shows an inline error without searching")
    func invalidRegex() {
        let backend = ReplayFileSearchBackend(batches: [])
        let fixture = makeFixture(backend: backend)
        fixture.panel.queryBar.show(query: FileSearchQuery(pattern: "(", isRegex: true), showsDetails: false)
        fixture.panel.queryDidChange(immediate: true)
        #expect(backend.receivedQueries.isEmpty)
        #expect(fixture.panel.queryBar.queryField.toolTip == FileSearchStatusText.regexError(detail: nil))
    }

    @Test("Redundant visibility and presentation passes do not invalidate layout (#4931)")
    func redundantPassesDoNotInvalidateLayout() {
        let fixture = makeFixture(backend: ReplayFileSearchBackend(batches: []))
        let container = fixture.container
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        container.layoutSubtreeIfNeeded()
        container.needsLayout = false
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        #expect(!container.needsLayout)

        container.layoutSubtreeIfNeeded()
        container.needsLayout = false
        container.updatePresentation(.find)
        #expect(!container.needsLayout)

        container.layoutSubtreeIfNeeded()
        container.needsLayout = false
        container.updateVisibility(hasContent: false, isLoading: false, statusMessage: nil)
        #expect(container.needsLayout, "A genuine visibility change must still invalidate layout.")
    }

    /// 100,000 matches in 2,000 files streamed through the engine into the
    /// outline, measuring main-thread time per applied update.
    @Test("100k matches stream into the outline in bounded per-frame updates")
    func streamingPerformance() async throws {
        let files = 2_000
        let perFile = 50
        var batches: [[FileSearchFileMatches]] = []
        var batch: [FileSearchFileMatches] = []
        for file in 0..<files {
            batch.append(matches("/tmp/cmux-find-panel/Module\(file % 40)/File\(file).swift", lines: Array(1...perFile)))
            if batch.count == 8 {
                batches.append(batch)
                batch = []
            }
        }
        let backend = ReplayFileSearchBackend(batches: batches)
        let fixture = makeFixture(backend: backend)
        let panel = fixture.panel
        let engine = panel.session.engine
        let clock = ContinuousClock()
        var slowest = Duration.zero
        var total = Duration.zero
        var updates = 0
        let original = engine.onEvent
        engine.onEvent = { event in
            let elapsed = clock.measure { original?(event) }
            if case .changed = event {
                updates += 1
                total += elapsed
                slowest = max(slowest, elapsed)
            }
        }
        type("needle", into: panel)
        let started = clock.now
        panel.runSearchNow()
        try await waitUntil("100k results", timeout: .seconds(60)) { engine.phase == .finished(.completed) }
        let wall = clock.now - started

        print("PERF outline matches=\(engine.tree.matchCount) rows=\(panel.resultsView.numberOfRows) updates=\(updates) " +
            "mainThreadMs=\(total.components.seconds * 1000 + total.components.attoseconds / 1_000_000_000_000_000) " +
            "slowestUpdateMs=\(slowest.components.seconds * 1000 + slowest.components.attoseconds / 1_000_000_000_000_000) " +
            "wallMs=\(wall.components.seconds * 1000 + wall.components.attoseconds / 1_000_000_000_000_000)")
        #expect(engine.tree.matchCount == files * perFile)
        #expect(panel.resultsView.numberOfRows == files * (perFile + 1))
        #expect(slowest < .milliseconds(250), "One frame of streamed rows must not stall the main thread.")
    }
}

@Suite("Find open location")
struct FilePreviewRevealLocationTests {
    @Test("Line and column map to a range clamped to the line")
    func ranges() {
        let text = "first\r\nsecond line\nthird" as NSString
        #expect(FilePreviewRevealLocation(line: 1, column: 1, length: 5).range(in: text) == NSRange(location: 0, length: 5))
        #expect(FilePreviewRevealLocation(line: 2, column: 8, length: 4).range(in: text) == NSRange(location: 14, length: 4))
        #expect(FilePreviewRevealLocation(line: 2, column: 8, length: 99).range(in: text) == NSRange(location: 14, length: 4))
        #expect(FilePreviewRevealLocation(line: 3, column: 1, length: 5).range(in: text) == NSRange(location: 19, length: 5))
        #expect(FilePreviewRevealLocation(line: 9, column: 1, length: 1).range(in: text) == NSRange(location: text.length, length: 0))
    }
}

/// The SSH backend's remote script, run by a local /bin/sh: quoting,
/// ripgrep discovery and the missing-ripgrep report are exercised without
/// an SSH host.
@Suite("SSH search script", .serialized)
struct SSHRipgrepScriptTests {
    static let ripgrep: String? = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func run(script: String, matchLimit: Int = 100) async -> (FileSearchCompletion, [FileSearchFileMatches]) {
        let mailbox = FileSearchBatchMailbox()
        let completion = await RipgrepStreamingSearch.run(
            command: FileSearchCommand(executablePath: "/bin/sh", arguments: ["-s"], standardInput: Data(script.utf8)),
            matchLimit: matchLimit,
            sink: mailbox
        )
        return (completion, mailbox.drain().groups)
    }

    @Test("Missing rg reports ripgrepNotFound")
    func missingRipgrep() async {
        let script = "PATH=/nonexistent\n" + SSHRipgrepFileSearchBackend.remoteScript(
            ripgrepArguments: RipgrepArguments.make(query: FileSearchQuery(pattern: "x"), rootPath: "/tmp"),
            fallbackDirectories: []
        )
        let (completion, groups) = await run(script: script)
        #expect(completion == .failed(.ripgrepNotFound))
        #expect(groups.isEmpty)
    }

    @Test("Quotes, backslashes and non-ASCII survive the remote shell", .enabled(if: SSHRipgrepScriptTests.ripgrep != nil))
    func quoting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let needle = #"it's a \d caf"# + "\u{E9}"
        try "before \(needle) after\n".write(to: root.appendingPathComponent("it's.txt"), atomically: true, encoding: .utf8)
        let directory = try #require(Self.ripgrep).replacingOccurrences(of: "/rg", with: "")
        let script = "PATH=/nonexistent\n" + SSHRipgrepFileSearchBackend.remoteScript(
            ripgrepArguments: RipgrepArguments.make(query: FileSearchQuery(pattern: needle), rootPath: root.path),
            fallbackDirectories: [directory]
        )
        let (completion, groups) = await run(script: script)
        #expect(completion == .completed)
        #expect(groups.map { ($0.path as NSString).lastPathComponent } == ["it's.txt"])
        #expect(groups.first?.matches.first?.column == 8)
    }
}
