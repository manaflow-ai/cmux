import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class PaletteClientRecorder {
    var refreshCount = 0
    var searchQueries: [String] = []
    var searchResults: [SearchIndexHit] = []
    var browseResults: [SearchIndexHit] = []
    var activated: [(hit: SearchIndexHit, query: String)] = []
    var dismissCount = 0
    var paletteVisible = true

    func makeClient() -> GlobalSearchPaletteModel.Client {
        GlobalSearchPaletteModel.Client(
            refreshLiveIndex: { self.refreshCount += 1 },
            search: { query in
                self.searchQueries.append(query)
                return self.searchResults
            },
            browseOpenPanels: { _ in self.browseResults },
            activate: { hit, query in self.activated.append((hit, query)) },
            dismissPalette: { self.dismissCount += 1 },
            isPaletteVisible: { self.paletteVisible }
        )
    }
}

private func makeHit(id: String = "hit-1", title: String = "Panel") -> SearchIndexHit {
    SearchIndexHit(
        id: id,
        windowID: UUID(),
        workspaceID: UUID(),
        panelID: UUID(),
        kind: .title,
        title: title,
        location: "Window > Workspace",
        anchor: "panel",
        snippet: title,
        rank: 0,
        timestamp: .now
    )
}

private func makeKeyEvent(
    keyCode: UInt16,
    characters: String? = nil,
    modifierFlags: NSEvent.ModifierFlags = []
) -> GlobalSearchKeyEvent {
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters ?? "",
        charactersIgnoringModifiers: characters ?? "",
        isARepeat: false,
        keyCode: keyCode
    )!
    return GlobalSearchKeyEvent(event)
}

@MainActor
@Suite(.serialized) struct GlobalSearchPaletteModelTests {
    @Test func prepareForOpenRefreshesLiveIndexOnEveryOpen() async throws {
        let recorder = PaletteClientRecorder()
        let model = GlobalSearchPaletteModel(client: recorder.makeClient())

        model.prepareForOpen()
        model.prepareForOpen()
        // The refresh task is scheduled on the main actor; let it run.
        try await Task.sleep(for: .milliseconds(50))

        #expect(recorder.refreshCount == 2)
        #expect(model.openGeneration == 2)
    }

    @Test func prepareForOpenResetsStaleQueryAndSelection() {
        let recorder = PaletteClientRecorder()
        recorder.browseResults = [makeHit()]
        let model = GlobalSearchPaletteModel(client: recorder.makeClient())
        model.query = "stale query"
        model.selectedIndex = 3

        model.prepareForOpen()

        #expect(model.query.isEmpty)
        #expect(model.selectedIndex == 0)
        #expect(model.results.count == 1)
    }

    @Test func queryChangeRunsDebouncedSearch() async throws {
        let recorder = PaletteClientRecorder()
        recorder.searchResults = [makeHit(id: "match")]
        let model = GlobalSearchPaletteModel(
            client: recorder.makeClient(),
            searchDebounceDelay: .milliseconds(1)
        )

        model.queryDidChange("needle")
        try await Task.sleep(for: .milliseconds(80))

        #expect(recorder.searchQueries == ["needle"])
        #expect(model.results.map(\.id) == ["match"])
        #expect(!model.isSearching)
    }

    @Test func returnKeyActivatesSelectedResult() async throws {
        let recorder = PaletteClientRecorder()
        recorder.searchResults = [makeHit(id: "first"), makeHit(id: "second")]
        let model = GlobalSearchPaletteModel(
            client: recorder.makeClient(),
            searchDebounceDelay: .milliseconds(1)
        )
        model.queryDidChange("needle")
        try await Task.sleep(for: .milliseconds(80))

        model.selectedIndex = 1
        let consumed = model.handleKeyEvent(makeKeyEvent(keyCode: 36))

        #expect(consumed)
        #expect(recorder.activated.map(\.hit.id) == ["second"])
        #expect(recorder.activated.map(\.query) == ["needle"])
    }

    @Test func escapeDismissesPalette() {
        let recorder = PaletteClientRecorder()
        let model = GlobalSearchPaletteModel(client: recorder.makeClient())

        let consumed = model.handleKeyEvent(makeKeyEvent(keyCode: 53))

        #expect(consumed)
        #expect(recorder.dismissCount == 1)
    }

    @Test func arrowKeysClampSelectionToResults() {
        let recorder = PaletteClientRecorder()
        recorder.browseResults = [makeHit(id: "a"), makeHit(id: "b")]
        let model = GlobalSearchPaletteModel(client: recorder.makeClient())
        model.prepareForOpen()

        #expect(model.handleKeyEvent(makeKeyEvent(keyCode: 126)))
        #expect(model.selectedIndex == 0)
        #expect(model.handleKeyEvent(makeKeyEvent(keyCode: 125)))
        #expect(model.handleKeyEvent(makeKeyEvent(keyCode: 125)))
        #expect(model.selectedIndex == 1)
    }

    @Test func keyEventsIgnoredWhilePaletteHidden() {
        let recorder = PaletteClientRecorder()
        recorder.paletteVisible = false
        let model = GlobalSearchPaletteModel(client: recorder.makeClient())

        #expect(!model.handleKeyEvent(makeKeyEvent(keyCode: 36)))
        #expect(recorder.activated.isEmpty)
    }

    @Test func openResultOutOfBoundsDoesNothing() {
        let recorder = PaletteClientRecorder()
        let model = GlobalSearchPaletteModel(client: recorder.makeClient())

        model.openResult(at: 5)

        #expect(recorder.activated.isEmpty)
    }
}
