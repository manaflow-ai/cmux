import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TemplateRepositoryTests: XCTestCase {
    var tempDir: URL!
    var repo: TemplateRepository!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-templates-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = TemplateRepository(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testListTemplates() throws {
        let yaml = "tabs:\n  - title: terminal\n"
        try yaml.write(
            to: tempDir.appendingPathComponent("Basic.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let templates = repo.listTemplates()
        XCTAssertEqual(templates, ["Basic"])
    }

    func testListTemplatesIgnoresNonYamlFiles() throws {
        try "test".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(repo.listTemplates(), [])
    }

    func testListTemplatesReturnsEmptyForMissingDirectory() {
        let missingRepo = TemplateRepository(
            directory: tempDir.appendingPathComponent("nonexistent")
        )
        XCTAssertEqual(missingRepo.listTemplates(), [])
    }

    func testGetTemplateReturnsTabDefinitions() throws {
        let yaml = """
        tabs:
          - title: claude
            startupScript: Standard Claude
          - title: terminal
        """
        try yaml.write(
            to: tempDir.appendingPathComponent("AI Dev.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let template = try repo.getTemplate(named: "AI Dev")
        XCTAssertEqual(template.tabs.count, 2)
        XCTAssertEqual(template.tabs[0].title, "claude")
        XCTAssertEqual(template.tabs[0].startupScript, "Standard Claude")
        XCTAssertEqual(template.tabs[1].title, "terminal")
        XCTAssertNil(template.tabs[1].startupScript)
    }

    func testSaveTemplateWritesYaml() throws {
        let template = WorkspaceTemplate(tabs: [
            TemplateTabDefinition(title: "builder", startupScript: "Builder Script"),
            TemplateTabDefinition(title: "terminal", startupScript: nil)
        ])
        try repo.saveTemplate(named: "Custom", template: template)
        let path = tempDir.appendingPathComponent("Custom.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        // Verify it can be read back
        let loaded = try repo.getTemplate(named: "Custom")
        XCTAssertEqual(loaded.tabs.count, 2)
        XCTAssertEqual(loaded.tabs[0].title, "builder")
        XCTAssertEqual(loaded.tabs[0].startupScript, "Builder Script")
    }

    func testDeleteTemplateRemovesFile() throws {
        let yaml = "tabs:\n  - title: terminal\n"
        try yaml.write(
            to: tempDir.appendingPathComponent("Temp.yaml"),
            atomically: true,
            encoding: .utf8
        )
        try repo.deleteTemplate(named: "Temp")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("Temp.yaml").path
        ))
    }
}
