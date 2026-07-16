import AppKit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct WorkspaceActionParameterEditorTests {
    @Test
    func parameterEditorHasVisibleEditableFields() throws {
        let presentingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        presentingWindow.isReleasedWhenClosed = false
        presentingWindow.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = presentingWindow.attachedSheet {
                presentingWindow.endSheet(
                    sheet,
                    returnCode: .alertSecondButtonReturn
                )
            }
            presentingWindow.close()
        }

        let definition = CmuxWorkspaceDefinition(
            name: "{{ticket}} Parameter UI",
            cwd: "{{projectDir}}",
            params: [
                "ticket": "CMUX-8059",
                "projectDir": "/tmp/cmux",
            ]
        )
        let handled = WorkspaceActionParameterEditor(
            processEnvironment: [:]
        ).present(
            definition: definition,
            displayName: "Parameter UI Test",
            presentingWindow: presentingWindow,
            completion: { _ in }
        )

        #expect(handled)
        let sheet = try #require(presentingWindow.attachedSheet)
        let contentView = try #require(sheet.contentView)
        let grid = try #require(
            descendants(of: contentView).compactMap { $0 as? NSGridView }.first
        )
        let fields = descendants(of: grid).compactMap { $0 as? NSTextField }
            .filter(\.isEditable)

        #expect(grid.frame.width >= 320)
        #expect(grid.frame.height > 0)
        #expect(fields.count == 2)
        #expect(fields.map(\.stringValue).sorted() == ["/tmp/cmux", "CMUX-8059"])
        #expect(fields.allSatisfy { $0.frame.width >= 320 })
        #expect(fields.allSatisfy { $0.frame.height > 0 })
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { view in
            [view] + descendants(of: view)
        }
    }
}
