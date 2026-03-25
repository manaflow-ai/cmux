import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Mock script repository for testing parser script validation.
final class MockScriptRepository: ScriptRepositoryProtocol {
    let scripts: Set<String>

    init(scripts: [String]) {
        self.scripts = Set(scripts)
    }

    func hasScript(named name: String) -> Bool {
        scripts.contains(name)
    }
}

@MainActor
final class CmuxConfigParserTests: XCTestCase {

    func testParseSimpleConfig() throws {
        let yaml = """
        name: MyProject
        color: "#4A9EFF"
        tabs:
          - title: terminal
        """
        let result = try CmuxConfigParser.parse(
            yaml: yaml,
            projectDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        XCTAssertEqual(result.projectName, "MyProject")
        XCTAssertEqual(result.projectColor, "#4A9EFF")
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.tabDefinitions.count, 1)
        XCTAssertEqual(result.tabDefinitions[0].title, "terminal")
    }

    func testParseConfigWithGroups() throws {
        let yaml = """
        name: MyProject
        groups:
          - name: prod
            workingDirectory: ./prod
            tabs:
              - title: claude
              - title: terminal
          - name: dev
            workingDirectory: ./dev
            tabs:
              - title: terminal
        """
        let result = try CmuxConfigParser.parse(
            yaml: yaml,
            projectDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        // Groups produce tab definitions (no separate group objects)
        XCTAssertEqual(result.tabDefinitions.count, 3)
    }

    func testParseMinimalConfig() throws {
        let yaml = """
        name: Minimal
        """
        let result = try CmuxConfigParser.parse(
            yaml: yaml,
            projectDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertEqual(result.projectName, "Minimal")
        XCTAssertTrue(result.tabDefinitions.isEmpty)
    }

    func testParseNestedGroupsInSubGroupProducesWarning() throws {
        let yaml = """
        name: Test
        groups:
          - name: sub
            groups:
              - name: deep
                tabs:
                  - title: terminal
        """
        let result = try CmuxConfigParser.parse(
            yaml: yaml,
            projectDirectory: URL(fileURLWithPath: "/tmp")
        )
        XCTAssertTrue(result.warnings.contains(where: {
            if case .maxDepthExceeded = $0 { return true }
            return false
        }))
    }

    func testParseConfigUsesDirectoryNameWhenNameMissing() throws {
        let yaml = """
        tabs:
          - title: terminal
        """
        let result = try CmuxConfigParser.parse(
            yaml: yaml,
            projectDirectory: URL(fileURLWithPath: "/tmp/my-project")
        )
        XCTAssertEqual(result.projectName, "my-project")
    }

    func testParseGroupTabsExtracted() throws {
        let yaml = """
        name: Test
        groups:
          - name: backend
            workingDirectory: ./server
            tabs:
              - title: api
              - title: worker
        """
        let result = try CmuxConfigParser.parse(
            yaml: yaml,
            projectDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        XCTAssertEqual(result.tabDefinitions.count, 2)
        XCTAssertEqual(result.tabDefinitions[0].title, "api")
        XCTAssertEqual(result.tabDefinitions[1].title, "worker")
    }
}
