import Bonsplit
import XCTest

@MainActor
final class WorkspaceLocalFileBrowserRoutingTests: XCTestCase {
    private var previousBrowserDisabledValue: Any?

    override func setUp() {
        super.setUp()
        previousBrowserDisabledValue = UserDefaults.standard.object(forKey: BrowserAvailabilitySettings.disabledKey)
        BrowserAvailabilitySettings.setDisabled(false)
    }

    override func tearDown() {
        if let previousBrowserDisabledValue {
            UserDefaults.standard.set(previousBrowserDisabledValue, forKey: BrowserAvailabilitySettings.disabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
        }
        super.tearDown()
    }

    func testOpenFileSurfacesKeepsHTMLFilesInFilePreviewPanels() throws {
        let workspace = try XCTUnwrap(TabManager().tabs.first)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let htmlURL = try temporaryFile(extension: "html", contents: "<!doctype html><title>Drop</title>")
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let openedPanels = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [htmlURL.path],
            focus: true
        )

        let filePreviewPanel = try XCTUnwrap(openedPanels.first as? FilePreviewPanel)
        XCTAssertEqual((filePreviewPanel.filePath as NSString).resolvingSymlinksInPath, htmlURL.path)
    }

    func testExternalHTMLDropSplitCreatesFilePreviewPane() throws {
        let workspace = try XCTUnwrap(TabManager().tabs.first)
        let sourcePaneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let originalPaneCount = workspace.bonsplitController.allPaneIds.count
        let htmlURL = try temporaryFile(extension: "html", contents: "<!doctype html><body>Split</body>")
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let handled = workspace.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
            urls: [htmlURL],
            destination: .split(targetPane: sourcePaneId, orientation: .horizontal, insertFirst: false)
        ))

        XCTAssertTrue(handled)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, originalPaneCount + 1)
        XCTAssertTrue(
            workspace.panels.values.contains { panel in
                guard let filePreviewPanel = panel as? FilePreviewPanel else { return false }
                return (filePreviewPanel.filePath as NSString).resolvingSymlinksInPath == htmlURL.path
            }
        )
    }

    func testExternalProjectDropSplitCreatesProjectPane() throws {
        let workspace = try XCTUnwrap(TabManager().tabs.first)
        let sourcePaneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let originalPaneCount = workspace.bonsplitController.allPaneIds.count
        let projectURL = try temporaryProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let handled = workspace.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
            urls: [projectURL],
            destination: .split(targetPane: sourcePaneId, orientation: .horizontal, insertFirst: false)
        ))

        XCTAssertTrue(handled)
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, originalPaneCount + 1)
        XCTAssertTrue(
            workspace.panels.values.contains { panel in
                guard let projectPanel = panel as? ProjectPanel else { return false }
                return projectPanel.projectURL.standardizedFileURL == projectURL.standardizedFileURL
            }
        )
    }

    func testOpenFileSurfacesReusesExistingProjectPanel() throws {
        let workspace = try XCTUnwrap(TabManager().tabs.first)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let projectURL = try temporaryProjectDirectory()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let originalPanel = try XCTUnwrap(
            workspace.newProjectSurface(
                inPane: paneId,
                projectPath: projectURL.path,
                focus: true
            )
        )

        let reopenedPanels = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [projectURL.path],
            focus: true,
            reuseExisting: true
        )

        let reopenedProject = try XCTUnwrap(reopenedPanels.first as? ProjectPanel)
        XCTAssertEqual(reopenedProject.id, originalPanel.id)
    }

    func testOpenLocalFilePanelInBrowserToRightCreatesAdjacentBrowserTab() throws {
        let workspace = try XCTUnwrap(TabManager().tabs.first)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let htmlURL = try temporaryFile(extension: "html", contents: "<!doctype html><body>Adjacent</body>")
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let filePreviewPanel = try XCTUnwrap(
            workspace.newFilePreviewSurface(
                inPane: paneId,
                filePath: htmlURL.path,
                focus: true
            )
        )
        let anchorSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(filePreviewPanel.id))

        let browserPanel = try XCTUnwrap(
            workspace.openLocalFilePanelInBrowserToRight(panelId: filePreviewPanel.id)
        )
        let browserSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(browserPanel.id))
        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        let anchorIndex = try XCTUnwrap(tabs.firstIndex(where: { $0.id == anchorSurfaceId }))
        let browserIndex = try XCTUnwrap(tabs.firstIndex(where: { $0.id == browserSurfaceId }))

        XCTAssertEqual(browserPanel.currentURLForTabDuplication?.standardizedFileURL, htmlURL.standardizedFileURL)
        XCTAssertEqual(browserIndex, anchorIndex + 1)
    }

    func testOpenLocalFilePanelInBrowserRejectsPlainTextFiles() throws {
        let workspace = try XCTUnwrap(TabManager().tabs.first)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let textURL = try temporaryFile(extension: "txt", contents: "plain text\n")
        defer { try? FileManager.default.removeItem(at: textURL) }

        let filePreviewPanel = try XCTUnwrap(
            workspace.newFilePreviewSurface(
                inPane: paneId,
                filePath: textURL.path,
                focus: true
            )
        )

        XCTAssertNil(workspace.browserFileURLForPanel(panelId: filePreviewPanel.id))
        XCTAssertNil(workspace.openLocalFilePanelInBrowserToRight(panelId: filePreviewPanel.id))
    }

    private func temporaryFile(extension fileExtension: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-file-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryProjectDirectory() throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-project-\(UUID().uuidString)")
            .appendingPathExtension("xcodeproj")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data().write(to: projectURL.appendingPathComponent("project.pbxproj"))
        return projectURL
    }
}
