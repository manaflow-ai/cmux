import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FinderServicePathResolverTests: XCTestCase {
    func testOrderedUniqueDirectoriesUsesParentForFilesAndDedupes() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/project/README.md", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/../cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/other", isDirectory: true),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/project",
                "/tmp/cmux-services/other",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesFirstSeenOrder() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/b", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/a/file.txt", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/b/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/b",
                "/tmp/cmux-services/a",
            ]
        )
    }
}


final class VSCodeServeWebURLBuilderTests: XCTestCase {
    func testExtractWebUIURLParsesServeWebOutput() {
        let output = """
        *
        * Visual Studio Code Server
        *
        Web UI available at http://127.0.0.1:5555?tkn=test-token
        """

        let url = VSCodeServeWebURLBuilder.extractWebUIURL(from: output)
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:5555?tkn=test-token")
    }

    func testOpenFolderURLAppendsFolderQueryWhilePreservingToken() {
        let baseURL = URL(string: "http://127.0.0.1:5555?tkn=test-token")!

        let url = VSCodeServeWebURLBuilder.openFolderURL(
            baseWebUIURL: baseURL,
            directoryPath: "/Users/tester/Projects/cmux"
        )

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "tkn" })?.value, "test-token")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "folder" })?.value, "/Users/tester/Projects/cmux")
    }

    func testOpenFolderURLReplacesExistingFolderQuery() {
        let baseURL = URL(string: "http://127.0.0.1:5555?tkn=test-token&folder=/tmp/old")!

        let url = VSCodeServeWebURLBuilder.openFolderURL(
            baseWebUIURL: baseURL,
            directoryPath: "/Users/tester/New Folder"
        )

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.queryItems?.filter { $0.name == "folder" }.count,
            1
        )
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "folder" })?.value,
            "/Users/tester/New Folder"
        )
    }
}


final class VSCodeCLILaunchConfigurationBuilderTests: XCTestCase {
    func testLaunchConfigurationUsesCodeTunnelBinary() {
        let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
        let expectedExecutablePath = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"

        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: appURL,
            baseEnvironment: [:],
            isExecutableAtPath: { $0 == expectedExecutablePath }
        )

        XCTAssertEqual(configuration?.executableURL.path, expectedExecutablePath)
        XCTAssertEqual(configuration?.argumentsPrefix, [])
        XCTAssertEqual(configuration?.environment["ELECTRON_RUN_AS_NODE"], "1")
    }

    func testLaunchConfigurationMapsNodeEnvironmentVariables() {
        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "NODE_OPTIONS": "--max-old-space-size=4096",
                "NODE_REPL_EXTERNAL_MODULE": "module-name"
            ],
            isExecutableAtPath: { _ in true }
        )

        XCTAssertEqual(configuration?.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(configuration?.environment["VSCODE_NODE_OPTIONS"], "--max-old-space-size=4096")
        XCTAssertEqual(configuration?.environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"], "module-name")
        XCTAssertNil(configuration?.environment["NODE_OPTIONS"])
        XCTAssertNil(configuration?.environment["NODE_REPL_EXTERNAL_MODULE"])
    }

    func testLaunchConfigurationClearsStaleVSCodeNodeVariablesWhenNodeVariablesAreAbsent() {
        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "VSCODE_NODE_OPTIONS": "--stale",
                "VSCODE_NODE_REPL_EXTERNAL_MODULE": "stale-module"
            ],
            isExecutableAtPath: { _ in true }
        )

        XCTAssertEqual(configuration?.environment["PATH"], "/usr/bin:/bin")
        XCTAssertNil(configuration?.environment["VSCODE_NODE_OPTIONS"])
        XCTAssertNil(configuration?.environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"])
    }
}


final class ServeWebOutputCollectorTests: XCTestCase {
    func testWaitForURLReturnsFalseAfterProcessExitSignal() {
        let collector = ServeWebOutputCollector()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            collector.markProcessExited()
        }

        let start = Date()
        let resolved = collector.waitForURL(timeoutSeconds: 1)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(resolved)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testWaitForURLReturnsTrueWhenURLIsCollected() {
        let collector = ServeWebOutputCollector()
        let urlLine = "Web UI available at http://127.0.0.1:7777?tkn=test-token\n"

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            collector.append(Data(urlLine.utf8))
        }

        XCTAssertTrue(collector.waitForURL(timeoutSeconds: 1))
        XCTAssertEqual(collector.webUIURL?.absoluteString, "http://127.0.0.1:7777?tkn=test-token")
    }

    func testMarkProcessExitedParsesFinalURLWithoutTrailingNewline() {
        let collector = ServeWebOutputCollector()
        let finalChunk = "Web UI available at http://127.0.0.1:9001?tkn=final-token"

        collector.append(Data(finalChunk.utf8))
        collector.markProcessExited()

        XCTAssertTrue(collector.waitForURL(timeoutSeconds: 0.1))
        XCTAssertEqual(collector.webUIURL?.absoluteString, "http://127.0.0.1:9001?tkn=final-token")
    }
}


final class VSCodeServeWebControllerTests: XCTestCase {
    func testStopDuringInFlightLaunchDoesNotDropNextGenerationCompletion() {
        let firstLaunchStarted = expectation(description: "first launch started")
        let firstCompletionCalled = expectation(description: "first generation completion called")
        let secondCompletionCalled = expectation(description: "second generation completion called")

        let launchGate = DispatchSemaphore(value: 0)
        let launchCallLock = NSLock()
        var launchCallCount = 0

        let controller = VSCodeServeWebController.makeForTesting { _, _ in
            launchCallLock.lock()
            launchCallCount += 1
            let callNumber = launchCallCount
            launchCallLock.unlock()

            if callNumber == 1 {
                firstLaunchStarted.fulfill()
                _ = launchGate.wait(timeout: .now() + 1)
            }
            return nil
        }

        let callbackLock = NSLock()
        var firstGenerationCallbacks: [URL?] = []
        var secondGenerationCallbacks: [URL?] = []
        let vscodeAppURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)

        controller.ensureServeWebURL(vscodeApplicationURL: vscodeAppURL) { url in
            callbackLock.lock()
            firstGenerationCallbacks.append(url)
            callbackLock.unlock()
            firstCompletionCalled.fulfill()
        }

        wait(for: [firstLaunchStarted], timeout: 1)
        controller.stop()

        controller.ensureServeWebURL(vscodeApplicationURL: vscodeAppURL) { url in
            callbackLock.lock()
            secondGenerationCallbacks.append(url)
            callbackLock.unlock()
            secondCompletionCalled.fulfill()
        }

        launchGate.signal()
        wait(for: [firstCompletionCalled, secondCompletionCalled], timeout: 2)

        callbackLock.lock()
        let firstSnapshot = firstGenerationCallbacks
        let secondSnapshot = secondGenerationCallbacks
        callbackLock.unlock()

        launchCallLock.lock()
        let launchCalls = launchCallCount
        launchCallLock.unlock()

        XCTAssertEqual(firstSnapshot.count, 1)
        if firstSnapshot.count == 1 {
            XCTAssertNil(firstSnapshot[0])
        }
        XCTAssertEqual(secondSnapshot.count, 1)
        if secondSnapshot.count == 1 {
            XCTAssertNil(secondSnapshot[0])
        }
        XCTAssertEqual(launchCalls, 2)
    }

    func testStopRemovesOrphanedConnectionTokenFiles() throws {
        let tokenFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tokenFileURL) }
        try Data("token".utf8).write(to: tokenFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenFileURL.path))

        let controller = VSCodeServeWebController.makeForTesting { _, _ in
            XCTFail("Expected no launch")
            return nil
        }
        controller.trackConnectionTokenFileForTesting(tokenFileURL)

        controller.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFileURL.path))
    }
}


final class OmnibarStateMachineTests: XCTestCase {
    func testEscapeRevertsWhenEditingThenBlursOnSecondEscape() throws {
        var state = OmnibarState()

        var effects = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(effects.shouldSelectAll)

        effects = omnibarReduce(state: &state, event: .bufferChanged("exam"))
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.buffer, "exam")
        XCTAssertTrue(effects.shouldRefreshSuggestions)

        // Simulate an open popup.
        effects = omnibarReduce(
            state: &state,
            event: .suggestionsUpdated([.search(engineName: "Google", query: "exam")])
        )
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertFalse(effects.shouldSelectAll)

        // First escape: revert + close popup + select-all.
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(state.suggestions.isEmpty)
        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertFalse(effects.shouldBlurToWebView)

        // Second escape: blur (since we're not editing and popup is closed).
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertTrue(effects.shouldBlurToWebView)
    }

    func testPanelURLChangeDoesNotClobberUserBufferWhileEditing() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://a.test/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("hello"))
        XCTAssertTrue(state.isUserEditing)

        _ = omnibarReduce(state: &state, event: .panelURLChanged(currentURLString: "https://b.test/"))
        XCTAssertEqual(state.currentURLString, "https://b.test/")
        XCTAssertEqual(state.buffer, "hello")
        XCTAssertTrue(state.isUserEditing)

        let effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://b.test/")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusLostRevertsUnlessSuppressed() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusLostPreserveBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed2"))
        _ = omnibarReduce(state: &state, event: .focusLostRevertBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "https://example.com/")
    }

    func testSuggestionsUpdateKeepsSelectionAcrossNonEmptyListRefresh() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let base: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(base))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 2))
        XCTAssertEqual(state.selectedSuggestionIndex, 2)

        // Simulate remote merge update for the same query while popup remains open.
        let merged: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
            .remoteSearchSuggestion("go fmt"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(merged))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected selection to remain stable while list stays open")
    }

    func testSuggestionsReopenResetsSelectionToFirstRow() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        XCTAssertEqual(state.selectedSuggestionIndex, 1)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([]))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 0, "Expected reopened popup to focus first row")
    }

    func testSuggestionsUpdatePrefersAutocompleteMatchWhenSelectionNotTracked() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "gm"),
            .history(url: "https://google.com/", title: "Google"),
            .history(url: "https://gmail.com/", title: "Gmail"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected autocomplete candidate to become selected without explicit index state.")
        XCTAssertEqual(state.selectedSuggestionID, rows[2].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[state.selectedSuggestionIndex]))
        XCTAssertEqual(state.suggestions[state.selectedSuggestionIndex].completion, "https://gmail.com/")
    }
}


final class OmnibarRemoteSuggestionMergeTests: XCTestCase {
    func testMergeRemoteSuggestionsInsertsBelowSearchAndDedupes() {
        let now = Date()
        let entries: [BrowserHistoryStore.Entry] = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 10
            ),
        ]

        let merged = buildOmnibarSuggestions(
            query: "go",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["go tutorial", "go.dev", "go json"],
            resolvedURL: nil,
            limit: 8
        )

        let completions = merged.compactMap { $0.completion }
        XCTAssertGreaterThanOrEqual(completions.count, 5)
        XCTAssertEqual(completions[0], "https://go.dev/")
        XCTAssertEqual(completions[1], "go")

        let remoteCompletions = Array(completions.dropFirst(2))
        XCTAssertEqual(Set(remoteCompletions), Set(["go tutorial", "go.dev", "go json"]))
        XCTAssertEqual(remoteCompletions.count, 3)
    }

    func testStaleRemoteSuggestionsKeptForNearbyEdits() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "go t",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json", "golang tips"],
            limit: 8
        )

        XCTAssertEqual(stale, ["go tutorial", "go json", "golang tips"])
    }

    func testStaleRemoteSuggestionsTrimAndRespectLimit() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "gooo",
            previousRemoteQuery: "goo",
            previousRemoteSuggestions: [" go tutorial ", "", "go json", "   ", "go fmt"],
            limit: 2
        )

        XCTAssertEqual(stale, ["go tutorial", "go json"])
    }

    func testStaleRemoteSuggestionsDroppedForUnrelatedQuery() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "python",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json"],
            limit: 8
        )

        XCTAssertTrue(stale.isEmpty)
    }
}


final class OmnibarSuggestionRankingTests: XCTestCase {
    private var fixedNow: Date {
        Date(timeIntervalSinceReferenceDate: 10_000_000)
    }

    func testSingleCharacterQueryPromotesAutocompletionMatchToFirstRow() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "n",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["search google for n", "news"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertNotEqual(results.map(\.completion).first, "n")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "n", suggestion: $0) } ?? false)
    }

    func testGmAutocompleteCandidateIsFirstOnExactQueryMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["gmail", "gmail.com", "google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        let inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: "gm",
            suggestions: results,
            isFocused: true,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )
        XCTAssertNotNil(inlineCompletion)
    }

    func testAutocompletionCandidateWinsOverRemoteAndSearchRowsForTwoLetterQuery() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://gmail.com/",
                    title: "Gmail",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com", "Google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
    }

    func testSuggestionSelectionPrefersAutocompletionCandidateAfterSuggestionsUpdate() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        var state = OmnibarState()
        let _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: ""))
        let _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))
        let _ = omnibarReduce(state: &state, event: .suggestionsUpdated(results))

        XCTAssertEqual(state.selectedSuggestionIndex, 0)
        XCTAssertEqual(state.selectedSuggestionID, results[0].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[0]))
    }

    func testTwoCharQueryWithRemoteSuggestionsStillPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "ne",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["netflix", "new york times", "newegg"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // The autocompletable history entry (news.ycombinator.com) should be first despite remote results.
        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "ne", suggestion: $0) } ?? false)

        // Remote suggestions should still appear in the results (two-char queries include them).
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions to be present for two-char query")
    }

    func testGmQueryWithRemoteSuggestionsAndOpenTabPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://google.com/maps",
                    title: "Google Maps",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["gmail login", "gm stock price", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // Gmail should be first (autocompletable + typed history).
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        // Verify remote suggestions are present alongside history/tab matches.
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions in results")
        let hasSearch = results.contains {
            if case .search = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasSearch, "Expected search row in results")
    }

    func testHistorySuggestionDisplaysTitleAndUrlOnSingleLine() {
        let row = OmnibarSuggestion.history(
            url: "https://www.example.com/path?q=1",
            title: "Example Domain"
        )
        XCTAssertEqual(row.listText, "Example Domain — example.com/path?q=1")
        XCTAssertFalse(row.listText.contains("\n"))
    }

    func testPublishedBufferTextUsesTypedPrefixWhenInlineSuffixIsSelected() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: inline.displayText,
            inlineCompletion: inline,
            selectionRange: inline.suffixRange,
            hasMarkedText: false
        )

        XCTAssertEqual(published, "l")
    }

    func testPublishedBufferTextKeepsUserTypedValueWhenDisplayDiffersFromInlineText() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: "la",
            inlineCompletion: inline,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )

        XCTAssertEqual(published, "la")
    }

    func testInlineCompletionRenderIgnoresStaleTypedPrefixMismatch() {
        let staleInline = OmnibarInlineCompletion(
            typedText: "g",
            displayText: "github.com",
            acceptedText: "https://github.com/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: staleInline
        )

        XCTAssertNil(active)
    }

    func testInlineCompletionRenderKeepsMatchingTypedPrefix() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: inline
        )

        XCTAssertEqual(active, inline)
    }

    func testInlineCompletionSkipsTitleMatchWhoseURLDoesNotStartWithTypedText() {
        // History entry: visited google.com/search?q=localhost:3000 with title
        // "localhost:3000 - Google Search". Typing "l" should NOT inline-complete
        // to "google.com/..." because that replaces the typed "l" with "g".
        let suggestions: [OmnibarSuggestion] = [
            .history(
                url: "https://www.google.com/search?q=localhost:3000",
                title: "localhost:3000 - Google Search"
            ),
        ]

        let result = omnibarInlineCompletionForDisplay(
            typedText: "l",
            suggestions: suggestions,
            isFocused: true,
            selectionRange: NSRange(location: 1, length: 0),
            hasMarkedText: false
        )

        XCTAssertNil(result, "Should not inline-complete when display text does not start with typed prefix")
    }
}
