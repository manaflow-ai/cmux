import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FinderFileDropRegressionTests: XCTestCase {
    private func make1x1PNG(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testOverlayCapturesFileURLDropsIncludingLocalPaneDrags() {
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL],
                hasLocalDraggingSource: false
            ),
            "Finder file drops should use the root AppKit overlay so terminal inputs receive the shared file-path insertion path"
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )

        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL, DragOverlayRoutingPolicy.filePreviewTransferType],
                hasLocalDraggingSource: true
            ),
            "Internal file-preview drags still need the shared pane drop destination so they can split or insert like Finder files"
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL, DragOverlayRoutingPolicy.bonsplitTabTransferType],
                hasLocalDraggingSource: true
            ),
            "Bonsplit tab drags use the same pane drop destination while tab-bar hit testing still defers to Bonsplit"
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL],
                hasLocalDraggingSource: true
            ),
            "File explorer drags are local file drags and must still reach the shared pane drop destination"
        )
    }

    func testPaneFileDropRoutingDefaultsToPreviewAndUsesShiftForTerminalDrops() {
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .terminal,
                hostsAgent: true,
                defaultAction: .filePreview,
                shiftKeyHeld: false
            ),
            .filePreview,
            "Plain Finder drops over terminal panes should open a file-preview pane by default"
        )
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .terminal,
                hostsAgent: true,
                defaultAction: .filePreview,
                shiftKeyHeld: true
            ),
            .agentPromptPaste,
            "Shift-dropping onto an agent terminal should attach images to the prompt instead of opening preview"
        )
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .terminal,
                hostsAgent: false,
                defaultAction: .filePreview,
                shiftKeyHeld: true
            ),
            .terminalPaste,
            "Shift-dropping onto a plain shell terminal should use the terminal path insertion route"
        )
    }

    func testPaneFileDropRoutingCanDefaultToTerminalAndUseShiftForPreview() {
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .terminal,
                hostsAgent: true,
                defaultAction: .terminal,
                shiftKeyHeld: false
            ),
            .agentPromptPaste
        )
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .terminal,
                hostsAgent: false,
                defaultAction: .terminal,
                shiftKeyHeld: false
            ),
            .terminalPaste
        )
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .terminal,
                hostsAgent: true,
                defaultAction: .terminal,
                shiftKeyHeld: true
            ),
            .filePreview
        )
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .filePreview,
                hostsAgent: true,
                defaultAction: .terminal,
                shiftKeyHeld: false
            ),
            .filePreview
        )
        XCTAssertEqual(
            PaneDropRouting.externalFileDropRouting(
                panelType: .markdown,
                hostsAgent: true,
                defaultAction: .terminal,
                shiftKeyHeld: false
            ),
            .filePreview
        )
    }

    func testTerminalFileDropSettingsDefaultToFilePreview() throws {
        let suiteName = "cmux-file-drop-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TerminalFileDropSettings.defaultAction(defaults: defaults), .filePreview)

        defaults.set(
            TerminalFileDropSettings.Action.terminal.rawValue,
            forKey: TerminalFileDropSettings.defaultActionKey
        )
        XCTAssertEqual(TerminalFileDropSettings.defaultAction(defaults: defaults), .terminal)

        defaults.set("unknown", forKey: TerminalFileDropSettings.defaultActionKey)
        XCTAssertEqual(TerminalFileDropSettings.defaultAction(defaults: defaults), .filePreview)
    }

    func testAgentStatusKeysTrackAgentTerminalDropRouting() {
        XCTAssertTrue(TerminalController.shouldTrackAgentStatusKey("pi"))
        XCTAssertTrue(TerminalController.shouldTrackAgentStatusKey("pi.session"))
        XCTAssertTrue(TerminalController.shouldTrackAgentStatusKey("hermes-agent"))
        XCTAssertTrue(TerminalController.shouldTrackAgentStatusKey("hermes-agent.session"))
        XCTAssertFalse(TerminalController.shouldTrackAgentStatusKey("plain_shell"))
    }

    func testAgentRoutingSnapshotCleanupClearsInvalidationFingerprint() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let index = try makeCodexRestorableAgentIndex(
            workspaceId: workspace.id,
            panelId: panelId,
            sessionId: "codex-routing-cleanup-session"
        )

        _ = workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: index)
        XCTAssertEqual(workspace.externalFileDropRouting(forPanelId: panelId), .agentPromptPaste)

        workspace.clearAgentTerminal(key: "pi", panelId: panelId)
        XCTAssertEqual(workspace.externalFileDropRouting(forPanelId: panelId), .agentPromptPaste)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        XCTAssertNil(
            workspace.sessionSnapshot(
                includeScrollback: false,
                restorableAgentIndex: index
            ).panels.first?.terminal?.agent
        )

        workspace.clearRestoredAgentSnapshotForAgentRouting(panelId: panelId)
        XCTAssertEqual(workspace.externalFileDropRouting(forPanelId: panelId), .filePreview)

        let acceptedSnapshot = workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: index)
        XCTAssertEqual(acceptedSnapshot.panels.first?.terminal?.agent?.sessionId, "codex-routing-cleanup-session")
        XCTAssertEqual(workspace.externalFileDropRouting(forPanelId: panelId), .agentPromptPaste)
    }

    func testAgentPromptDropPasteUsesTextPastePathWithoutEmbeddingControlSequences() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent dropped \(UUID().uuidString)")
            .appendingPathExtension("png")

        let escapedPath = TerminalImageTransferPlanner.escapeForShell(fileURL.path)
        let pastedText = TerminalAgentPromptPaste.text(for: escapedPath)

        XCTAssertEqual(pastedText, escapedPath)
        XCTAssertFalse(pastedText.unicodeScalars.contains { $0.value == 0x1B })
    }

    func testLegacyFinderFilenameDropPlanInsertsEscapedLocalPath() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder legacy \(UUID().uuidString)")
            .appendingPathExtension("png")
        try make1x1PNG(color: .systemBlue).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard(name: .init("cmux-test-legacy-filename-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setPropertyList(
            [fileURL.path],
            forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        )

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: false
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected local path insertion, got \(plan)")
        }

        XCTAssertEqual(text, TerminalImageTransferPlanner.escapeForShell(fileURL.path))
    }

    func testFileExplorerPathInsertionEscapesMultiplePathsLikeTerminalDrop() {
        let paths = [
            "/tmp/cmux path/one file.txt",
            "/tmp/cmux path/quote's file.txt"
        ]

        let text = FileExplorerTerminalPathInsertion.insertedText(forPaths: paths)

        XCTAssertEqual(
            text,
            paths
                .map(TerminalImageTransferPlanner.escapeForShell)
                .joined(separator: " ")
        )
    }

    func testFileExplorerRelativePathInsertionUsesWorkspaceRelativePaths() {
        let rootPath = "/Users/example/project"
        let paths = [
            "/Users/example/project/README.md",
            "/Users/example/project/Folder With Spaces/file.txt"
        ]

        let text = FileExplorerTerminalPathInsertion.insertedText(
            forPaths: paths,
            relativeToRootPath: rootPath
        )

        XCTAssertEqual(text, "README.md Folder\\ With\\ Spaces/file.txt")
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: rootPath,
                rootPath: rootPath
            ),
            "."
        )
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: rootPath,
                rootPath: rootPath + "/"
            ),
            "."
        )
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: "/Users/example/project-backup/file.txt",
                rootPath: rootPath
            ),
            "/Users/example/project-backup/file.txt"
        )
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: "Sources/App.swift",
                rootPath: rootPath
            ),
            "Sources/App.swift"
        )
    }

    func testFileExplorerRelativePathInsertionStandardizesMacOSSymlinkedRoots() {
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: "/private/tmp/cmux-project/Sources/App.swift",
                rootPath: "/tmp/cmux-project"
            ),
            "Sources/App.swift"
        )
    }

    private func makeCodexRestorableAgentIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let now = Date().timeIntervalSince1970
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": "/tmp/repo",
                    "updatedAt": now,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": ["/usr/local/bin/codex", "--model", "gpt-5.4"],
                        "workingDirectory": "/tmp/repo",
                        "environment": ["CODEX_HOME": "/tmp/codex"],
                        "capturedAt": now,
                        "source": "process",
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)
        return RestorableAgentSessionIndex.load(homeDirectory: home.path)
    }
}
