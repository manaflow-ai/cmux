import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for stale runtime snapshots posted out of revision order.
///
/// The page runtime posts revisioned snapshots asynchronously. A delayed post
/// from before a `removeSelection` response can arrive after the authoritative
/// newer snapshot was applied. The controller must reject the stale snapshot
/// entirely: it must not reopen the composer or derive any UI state from a
/// snapshot that lost the revision comparison.
@MainActor
@Suite(.serialized)
struct BrowserDesignModeControllerSnapshotRevisionTests {
    private func makeController() -> BrowserDesignModeController {
        BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            screenshotStore: BrowserDesignModeScreenshotStore(directory: URL.temporaryDirectory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
            canEnable: { true },
            clipboardWriter: { _ in true },
            onActivityChanged: {}
        )
    }

    private func makeSelection(selector: String) -> BrowserDesignModeSelection {
        BrowserDesignModeSelection(
            selector: selector,
            selectors: [selector],
            tagName: "div",
            domSnippet: "<div></div>",
            textContent: "",
            textEditable: false,
            bounds: BrowserDesignModeRect(x: 0, y: 0, width: 10, height: 10),
            viewport: BrowserDesignModeViewport(width: 800, height: 600),
            computedStyles: [:]
        )
    }

    private func makeSnapshotData(revision: Int, selectors: [String]) throws -> Data {
        let snapshot = BrowserDesignModeSnapshot(
            revision: revision,
            enabled: true,
            selection: nil,
            selections: selectors.map(makeSelection(selector:)),
            edits: [],
            cssDiff: ""
        )
        return try JSONEncoder().encode(snapshot)
    }

    @Test func staleSnapshotDoesNotReopenTheComposer() throws {
        let controller = makeController()
        controller.activateForTesting()

        controller.receiveSnapshotDataForTesting(
            try makeSnapshotData(revision: 1, selectors: ["#hero"])
        )
        #expect(controller.isComposerPresented)

        controller.receiveSnapshotDataForTesting(
            try makeSnapshotData(revision: 2, selectors: [])
        )
        #expect(!controller.isComposerPresented)
        #expect(controller.snapshot?.revision == 2)

        // A delayed post from before the removal arrives out of order.
        controller.receiveSnapshotDataForTesting(
            try makeSnapshotData(revision: 1, selectors: ["#hero"])
        )
        #expect(
            !controller.isComposerPresented,
            "A rejected stale snapshot must not reopen the composer"
        )
        #expect(controller.snapshot?.revision == 2)
    }

    @Test func staleSnapshotDoesNotReplaceNewerSelections() throws {
        let controller = makeController()
        controller.activateForTesting()

        controller.receiveSnapshotDataForTesting(
            try makeSnapshotData(revision: 5, selectors: ["#hero", "#nav"])
        )
        #expect(controller.snapshot?.revision == 5)

        controller.receiveSnapshotDataForTesting(
            try makeSnapshotData(revision: 3, selectors: ["#hero"])
        )
        #expect(
            controller.snapshot?.selections.map(\.selector) == ["#hero", "#nav"],
            "The authoritative snapshot must keep the newer selections"
        )
        #expect(controller.snapshot?.revision == 5)
    }
}
