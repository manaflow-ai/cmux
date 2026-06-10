import Combine
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding


// MARK: - Action icons
extension CmuxConfigDecodingTests {
    func testDecodeActionIconObjectsSupportAllFormats() throws {
        let json = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "id": "emoji", "icon": { "type": "emoji", "value": "🤖", "scale": 0.85 }, "command": "codex" },
                { "id": "svg", "icon": { "type": "image", "path": "./icons/codex.svg" }, "command": "codex" },
                { "id": "jpeg", "icon": { "type": "image", "path": "./icons/claude.jpg" }, "command": "claude" },
                { "id": "pdf", "icon": { "type": "image", "path": "./icons/logo.pdf" }, "command": "open ." },
                { "id": "bmp", "icon": { "type": "image", "path": "./icons/logo.bmp" }, "command": "open ." },
                { "id": "heif", "icon": { "type": "image", "path": "./icons/logo.heif" }, "command": "open ." },
                { "id": "avif", "icon": { "type": "image", "path": "./icons/logo.avif" }, "command": "open ." },
                { "id": "ico", "icon": { "type": "image", "path": "./icons/logo.ico" }, "command": "open ." }
              ]
            }
          }
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.surfaceTabBarButtons?[0].icon, .emoji("🤖", scale: 0.85))
        XCTAssertEqual(config.surfaceTabBarButtons?[1].icon, .imagePath("./icons/codex.svg"))
        XCTAssertEqual(config.surfaceTabBarButtons?[2].icon, .imagePath("./icons/claude.jpg"))
        XCTAssertEqual(config.surfaceTabBarButtons?[3].icon, .imagePath("./icons/logo.pdf"))
        XCTAssertEqual(config.surfaceTabBarButtons?[4].icon, .imagePath("./icons/logo.bmp"))
        XCTAssertEqual(config.surfaceTabBarButtons?[5].icon, .imagePath("./icons/logo.heif"))
        XCTAssertEqual(config.surfaceTabBarButtons?[6].icon, .imagePath("./icons/logo.avif"))
        XCTAssertEqual(config.surfaceTabBarButtons?[7].icon, .imagePath("./icons/logo.ico"))
    }

    func testDecodeStringIconThrows() {
        let json = """
        {
          "actions": {
            "start-codex": {
              "type": "command",
              "command": "codex",
              "icon": "sparkles"
            }
          }
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testGlobalSVGIconAllowsNamespaceAndInternalGradient() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let iconsDirectory = root.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configPath = root.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("codex.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <defs>
            <linearGradient id="grad">
              <stop offset="0%" stop-color="#000"/>
              <stop offset="100%" stop-color="#fff"/>
            </linearGradient>
          </defs>
          <rect width="24" height="24" fill="url(#grad)"/>
        </svg>
        """
        let data = Data(svg.utf8)
        try data.write(to: iconPath)

        let icon = CmuxButtonIcon.imagePath("icons/codex.svg")
        XCTAssertEqual(
            icon.bonsplitIcon(
                configSourcePath: configPath,
                globalConfigPath: configPath
            ),
            .imageData(data)
        )
    }

    func testProjectLocalSVGIconRejectsExternalReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let iconsDirectory = projectDirectory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigPath = globalDirectory.appendingPathComponent("cmux.json").path
        let projectConfigPath = projectDirectory.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("bad.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <image href="https://example.com/icon.png" width="24" height="24"/>
        </svg>
        """
        try Data(svg.utf8).write(to: iconPath)

        let icon = CmuxButtonIcon.imagePath("icons/bad.svg")
        XCTAssertEqual(
            icon.bonsplitIcon(
                configSourcePath: projectConfigPath,
                globalConfigPath: globalConfigPath
            ),
            .systemImage("questionmark.circle")
        )
    }

    func testUntrustedProjectLocalIconUsesLockPlaceholder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let iconsDirectory = projectDirectory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigPath = globalDirectory.appendingPathComponent("cmux.json").path
        let projectConfigPath = projectDirectory.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("safe.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" fill="#000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: iconPath)

        let icon = CmuxButtonIcon.imagePath("icons/safe.svg")
        XCTAssertEqual(
            icon.bonsplitIcon(
                configSourcePath: projectConfigPath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalImage: false
            ),
            .systemImage("lock.fill")
        )
    }

    @MainActor
    func testInlineSurfaceButtonIconUsesTabBarConfigSourceForTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-svg-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let iconsDirectory = projectDirectory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfigPath = globalDirectory.appendingPathComponent("cmux.json").path
        let projectConfigPath = projectDirectory.appendingPathComponent("cmux.json").path
        let iconPath = iconsDirectory.appendingPathComponent("safe.svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" fill="#000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: iconPath)

        let button = CmuxSurfaceTabBarButton(
            id: "inline-local",
            icon: .imagePath("icons/safe.svg"),
            action: .command("echo inline")
        )
        XCTAssertFalse(
            CmuxConfigExecutor.isTrustedSurfaceButton(
                button,
                workspaceCommand: nil,
                terminalCommandSourcePath: nil,
                surfaceTabBarConfigSourcePath: projectConfigPath,
                globalConfigPath: globalConfigPath
            )
        )
    }

}
