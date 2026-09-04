import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the phone's markdown / file-preview panel surface:
/// `mobile.panel.artifact.*` requests carry the PANEL surface id, which is not
/// a terminal, so workspace/surface resolution must not require a terminal
/// input target. When it does, the Mac answers `not_found` and the phone shows
/// "Panel closed" for a panel that is plainly open.
@MainActor
struct MobilePanelArtifactResolutionTests {
    @Test
    func statResolvesMarkdownPanelSurface() async throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)

        let contents = "# Panel surface stat\n"
        let fileURL = try temporaryMarkdownFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: firstPane,
            filePath: fileURL.path,
            focus: false
        ))

        let resolved = TerminalController.shared.mobileResolveWorkspaceAndSurface(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
            ],
            requireTerminal: false
        )
        #expect(resolved?.surfaceId == panel.id)

        let result = await TerminalController.shared.v2MobilePanelArtifactStat(params: [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panel.id.uuidString,
            "path": fileURL.path,
        ])
        switch result {
        case .ok(let payload):
            let stat = try #require(payload as? [String: Any])
            let size = try #require(stat["size"] as? NSNumber).int64Value
            #expect(size == Int64(contents.utf8.count))
        case .err(let code, let message, _):
            Issue.record("stat failed: \(code) \(message)")
        }
    }

    @Test
    func terminalResolutionStillRequiresTerminalTargets() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)

        let fileURL = try temporaryMarkdownFile(contents: "# Not a terminal\n")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: firstPane,
            filePath: fileURL.path,
            focus: false
        ))

        // Terminal-only callers (input, replay) must keep failing closed for a
        // markdown panel rather than resolving it as an input target.
        let resolved = TerminalController.shared.mobileResolveWorkspaceAndSurface(
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
            ],
            requireTerminal: true
        )
        #expect(resolved == nil)
    }

    private func temporaryMarkdownFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = window(withId: windowId) else { return }
        window.performClose(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
