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
        let yaml = "root:\n  title: Terminal\n"
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

    func testGetTemplateReturnsRootNode() throws {
        let yaml = """
        root:
          title: Terminal
          children:
            - title: claude
              color: "#00CC00"
              command: claude
            - title: terminal
        """
        try yaml.write(
            to: tempDir.appendingPathComponent("AI Dev.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let template = try repo.getTemplate(named: "AI Dev")
        XCTAssertEqual(template.root.title, "Terminal")
        XCTAssertEqual(template.root.children.count, 2)
        XCTAssertEqual(template.root.children[0].title, "claude")
        XCTAssertEqual(template.root.children[0].color, "#00CC00")
        XCTAssertEqual(template.root.children[0].command, "claude")
        XCTAssertEqual(template.root.children[1].title, "terminal")
        XCTAssertNil(template.root.children[1].command)
    }

    func testSaveTemplateWritesYaml() throws {
        let template = WorkspaceTemplate(root: TemplateNode(
            title: "Terminal",
            color: nil,
            command: nil,
            children: [
                TemplateNode(title: "builder", color: nil, command: "claude", children: []),
                TemplateNode(title: "terminal", color: nil, command: nil, children: [])
            ]
        ))
        try repo.saveTemplate(named: "Custom", template: template)
        let path = tempDir.appendingPathComponent("Custom.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        // Verify it can be read back
        let loaded = try repo.getTemplate(named: "Custom")
        XCTAssertEqual(loaded.root.children.count, 2)
        XCTAssertEqual(loaded.root.children[0].title, "builder")
        XCTAssertEqual(loaded.root.children[0].command, "claude")
    }

    func testDeleteTemplateRemovesFile() throws {
        let yaml = "root:\n  title: Terminal\n"
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
