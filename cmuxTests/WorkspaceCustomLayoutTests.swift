import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceCustomLayoutTests: XCTestCase {
    func testMarkdownSurfaceRequiresPathWhenDecodingLayout() throws {
        let json = """
        {
          "pane": {
            "surfaces": [
              { "type": "markdown" }
            ]
          }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertThrowsError(try JSONDecoder().decode(CmuxLayoutNode.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, let context) = error else {
                return XCTFail("Expected keyNotFound for markdown path, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "path")
            XCTAssertTrue(context.debugDescription.contains("Markdown surface requires"))
        }
    }

    func testMarkdownSurfaceRejectsBlankPathWhenDecodingLayout() throws {
        let json = """
        {
          "pane": {
            "surfaces": [
              { "type": "markdown", "path": "   " }
            ]
          }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        XCTAssertThrowsError(try JSONDecoder().decode(CmuxLayoutNode.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted for blank markdown path, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("must not be empty"))
        }
    }

    @MainActor
    func testCustomLayoutMarkdownSurfacesOpenInDeclaredPaneWithResolvedPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-layout-markdown-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readmeURL = root.appendingPathComponent("README.md")
        let planURL = docs.appendingPathComponent("plan.md")
        try "# Readme\n".write(to: readmeURL, atomically: true, encoding: .utf8)
        try "# Plan\n".write(to: planURL, atomically: true, encoding: .utf8)

        let layoutJSON = """
        {
          "pane": {
            "surfaces": [
              { "type": "markdown", "path": "README.md" },
              { "type": "markdown", "path": "docs/plan.md", "focus": true }
            ]
          }
        }
        """
        let layoutData = try XCTUnwrap(layoutJSON.data(using: .utf8))
        let layout = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)

        let workspace = Workspace()
        XCTAssertTrue(workspace.applyCustomLayout(layout, baseCwd: root.path))

        let markdownPanels = workspace.panels.values.compactMap { $0 as? MarkdownPanel }
        XCTAssertEqual(markdownPanels.count, 2)
        XCTAssertEqual(
            Set(markdownPanels.map(\.filePath)),
            Set([readmeURL.path, planURL.path])
        )

        let paneIDs = Set(markdownPanels.compactMap { workspace.paneId(forPanelId: $0.id)?.id })
        XCTAssertEqual(paneIDs.count, 1)

        let focusedMarkdownPanel = try XCTUnwrap(
            workspace.focusedPanelId.flatMap { workspace.markdownPanel(for: $0) }
        )
        XCTAssertEqual(focusedMarkdownPanel.filePath, planURL.path)
    }

    func testCustomLayoutMarkdownResolutionProducesAbsolutePathSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-layout-markdown-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readmeURL = root.appendingPathComponent("README.md")
        try "# Readme\n".write(to: readmeURL, atomically: true, encoding: .utf8)

        let layoutJSON = """
        {
          "pane": {
            "surfaces": [
              { "type": "terminal", "name": "shell" },
              { "type": "markdown", "path": "README.md" }
            ]
          }
        }
        """
        let layoutData = try XCTUnwrap(layoutJSON.data(using: .utf8))
        let layout = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)

        let resolved = layout.resolvingMarkdownPaths(relativeTo: root.path)
        XCTAssertNil(resolved.failure)

        let resolvedLayout = try XCTUnwrap(resolved.layout)
        guard case .pane(let pane) = resolvedLayout else {
            return XCTFail("Expected pane layout")
        }
        XCTAssertEqual(pane.surfaces[0].path, nil)
        XCTAssertEqual(pane.surfaces[1].path, readmeURL.path)
    }

    @MainActor
    func testCustomLayoutInvalidMarkdownPathFailsBeforeMutatingWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-layout-markdown-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let layoutJSON = """
        {
          "pane": {
            "surfaces": [
              { "type": "terminal", "name": "shell" },
              { "type": "markdown", "path": "missing.md" }
            ]
          }
        }
        """
        let layoutData = try XCTUnwrap(layoutJSON.data(using: .utf8))
        let layout = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)

        let failure = try XCTUnwrap(layout.firstMarkdownPathResolutionFailure(relativeTo: root.path))
        XCTAssertEqual(failure.code, "not_found")

        let workspace = Workspace()
        let initialPanelIds = Set(workspace.panels.keys)

        XCTAssertFalse(workspace.applyCustomLayout(layout, baseCwd: root.path))
        XCTAssertEqual(Set(workspace.panels.keys), initialPanelIds)
        XCTAssertTrue(workspace.panels.values.allSatisfy { $0 is TerminalPanel })
    }

    @MainActor
    func testNewWorkspaceLayoutBaseCwdInheritsSelectedWorkspaceDirectoryWhenCwdOmitted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-layout-markdown-inherited-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readmeURL = root.appendingPathComponent("README.md")
        try "# Readme\n".write(to: readmeURL, atomically: true, encoding: .utf8)

        let layoutJSON = """
        {
          "pane": {
            "surfaces": [
              { "type": "markdown", "path": "README.md" }
            ]
          }
        }
        """
        let layoutData = try XCTUnwrap(layoutJSON.data(using: .utf8))
        let layout = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)

        let tabManager = TabManager()
        let sourceWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        sourceWorkspace.currentDirectory = root.path

        let layoutBaseCwd = customLayoutBaseCwdForNewWorkspace(tabManager: tabManager, requestedCwd: nil)
        XCTAssertEqual(layoutBaseCwd, root.path)
        XCTAssertNil(layout.firstMarkdownPathResolutionFailure(relativeTo: layoutBaseCwd))

        let createdWorkspace = tabManager.addWorkspace(workingDirectory: layoutBaseCwd, select: false)
        XCTAssertEqual(createdWorkspace.currentDirectory, root.path)
    }

    @MainActor
    func testNewWorkspaceLayoutBaseCwdResolvesRelativeRequestedCwdFromInheritedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-layout-markdown-relative-cwd-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readmeURL = app.appendingPathComponent("README.md")
        try "# Readme\n".write(to: readmeURL, atomically: true, encoding: .utf8)

        let layoutJSON = """
        {
          "pane": {
            "surfaces": [
              { "type": "markdown", "path": "README.md" }
            ]
          }
        }
        """
        let layoutData = try XCTUnwrap(layoutJSON.data(using: .utf8))
        let layout = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)

        let tabManager = TabManager()
        let sourceWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        sourceWorkspace.currentDirectory = root.path

        let layoutBaseCwd = customLayoutBaseCwdForNewWorkspace(tabManager: tabManager, requestedCwd: "./app")
        XCTAssertEqual(layoutBaseCwd, app.path)
        XCTAssertNil(layout.firstMarkdownPathResolutionFailure(relativeTo: layoutBaseCwd))

        let createdWorkspace = tabManager.addWorkspace(workingDirectory: layoutBaseCwd, select: false)
        XCTAssertEqual(createdWorkspace.currentDirectory, app.path)
    }

    func testReadableFilePathResolverPreservesLiteralWhitespaceInFileNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-layout-markdown-whitespace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent(" note .md")
        try "# Note\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = CmuxReadableFilePathResolver.resolve(fileURL.path)
        XCTAssertEqual(result.path, fileURL.path)
        XCTAssertNil(result.failure)
    }

    @MainActor
    func testConfigWorkspaceCommandMarkdownLayoutResolvesRelativeBaseCwdToAbsolutePath() throws {
        let originalCwd = FileManager.default.currentDirectoryPath
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-config-layout-relative-base-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(originalCwd)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))

        let readmeURL = workspaceDir.appendingPathComponent("README.md")
        try "# Readme\n".write(to: readmeURL, atomically: true, encoding: .utf8)

        let layoutJSON = """
        {
          "pane": {
            "surfaces": [
              { "type": "markdown", "path": "README.md" }
            ]
          }
        }
        """
        let layoutData = try XCTUnwrap(layoutJSON.data(using: .utf8))
        let layout = try JSONDecoder().decode(CmuxLayoutNode.self, from: layoutData)
        let manager = TabManager()
        let command = CmuxCommandDefinition(
            name: "Docs command",
            workspace: CmuxWorkspaceDefinition(name: "Docs", cwd: "workspace", layout: layout)
        )

        XCTAssertTrue(CmuxConfigExecutor.execute(
            command: command,
            tabManager: manager,
            baseCwd: ".",
            configSourcePath: nil,
            globalConfigPath: "/tmp/cmux-test-global-config.json"
        ))

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        XCTAssertEqual(workspace.currentDirectory, workspaceDir.path)
        let markdownPanel = try XCTUnwrap(workspace.panels.values.compactMap { $0 as? MarkdownPanel }.first)
        XCTAssertEqual(markdownPanel.filePath, readmeURL.path)
    }
}
