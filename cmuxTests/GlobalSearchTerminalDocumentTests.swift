import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class StubTerminalContextPanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    var panelType: PanelType { .terminal }
    var displayTitle: String { "Stub Terminal" }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}

@MainActor
private func makeContext(
    panelID: UUID = UUID(),
    panelTitle: String = "agent — zsh"
) -> GlobalSearchPanelContext {
    GlobalSearchPanelContext(
        windowID: UUID(),
        windowTitle: "Window",
        workspaceID: UUID(),
        workspaceTitle: "Workspace",
        panelID: panelID,
        panelTitle: panelTitle,
        panel: StubTerminalContextPanel()
    )
}

@MainActor
@Suite struct GlobalSearchTerminalDocumentTests {
    @Test func buildsDocumentWithStableIDAndTerminalKind() throws {
        let panelID = UUID()
        let context = makeContext(panelID: panelID)

        let document = GlobalSearchDocuments.terminalDocument(for: context, text: "error: connection refused")

        let unwrapped = try #require(document)
        #expect(unwrapped.id == SearchIndexDocument.panelStableID(panelID: panelID, kind: .terminal))
        #expect(unwrapped.kind == .terminal)
        #expect(unwrapped.panelID == panelID)
        #expect(unwrapped.title == "agent — zsh")
        #expect(unwrapped.text == "error: connection refused")
        #expect(unwrapped.location == context.location)
    }

    @Test func rebuildingForTheSamePanelKeepsTheDocumentID() {
        let panelID = UUID()
        let first = GlobalSearchDocuments.terminalDocument(
            for: makeContext(panelID: panelID),
            text: "first capture"
        )
        let second = GlobalSearchDocuments.terminalDocument(
            for: makeContext(panelID: panelID),
            text: "second capture with more output"
        )

        #expect(first?.id == second?.id)
    }

    @Test func whitespaceOnlyScrollbackProducesNoDocument() {
        let document = GlobalSearchDocuments.terminalDocument(for: makeContext(), text: " \n\t\n ")

        #expect(document == nil)
    }

    @Test func oversizedScrollbackIsCappedToIndexingLimit() {
        let oversized = String(repeating: "x", count: GlobalSearchIndexingLimits.maxIndexedTextCharacters + 500)

        let document = GlobalSearchDocuments.terminalDocument(for: makeContext(), text: oversized)

        #expect(document?.text.count == GlobalSearchIndexingLimits.maxIndexedTextCharacters)
    }

    @Test func browseHitLabelsTerminalPanelsWithTerminalKind() {
        let context = makeContext()

        let hit = GlobalSearchDocuments.browseHit(for: context)

        #expect(hit.kind == .terminal)
    }
}
