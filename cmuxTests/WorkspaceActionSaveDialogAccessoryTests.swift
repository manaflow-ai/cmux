import AppKit
import struct CmuxWorkspaces.CmuxPaneDefinition
import struct CmuxWorkspaces.CmuxSurfaceDefinition
import struct CmuxWorkspaces.CmuxWorkspaceDefinition
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The "Save as Workspace Layout" dialog accessory: the disclosure sections
/// must actually render the sensitive commands/URLs/env-key text they exist
/// to show before the user confirms saving.
@Suite("Workspace action save dialog accessory")
struct WorkspaceActionSaveDialogAccessoryTests {
    @Test @MainActor func saveDialogDisclosureTextViewsSizeToTheirContent() {
        // Regression: the disclosure NSTextViews were created 1pt tall and
        // NSText clamps vertical growth to maxSize (which defaults to the
        // initial frame size), so the sensitive commands/URLs/env text the
        // dialog exists to show rendered blank inside its scroll view.
        let accessory = WorkspaceActionSaveDialogAccessory(
            snapshot: WorkspaceConfigActionSnapshot(
                definition: CmuxWorkspaceDefinition(
                    name: "W",
                    env: ["API_TOKEN": "secret"],
                    layout: .pane(CmuxPaneDefinition(surfaces: [
                        CmuxSurfaceDefinition(type: .terminal, command: "claude --model claude-fable-5"),
                        CmuxSurfaceDefinition(type: .browser, url: "https://example.com/callback?code=abc"),
                    ]))
                ),
                skippedPanelCount: 0
            ),
            initialName: "Layout"
        )

        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { subview -> [NSScrollView] in
                if let scrollView = subview as? NSScrollView { return [scrollView] }
                return scrollViews(in: subview)
            }
        }

        let disclosureScrollViews = scrollViews(in: accessory.view)
        #expect(disclosureScrollViews.count == 3)
        for scrollView in disclosureScrollViews {
            let textView = scrollView.documentView as? NSTextView
            #expect(textView != nil)
            guard let textView else { continue }
            #expect(!textView.string.isEmpty)
            // The document view must have grown to fit its laid-out text; a
            // 1pt-tall document view means the disclosure renders blank.
            #expect(textView.frame.height >= 20)
            #expect(textView.maxSize.height >= textView.frame.height)
        }
    }
}
