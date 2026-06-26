import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Variable parsing

final class CmuxCommandVariableParserTests: XCTestCase {

    func testNoPlaceholdersReturnsEmpty() {
        XCTAssertEqual(CmuxCommandVariableParser.variables(in: "npm test"), [])
        XCTAssertFalse(CmuxCommandVariableParser.containsVariables("npm test"))
    }

    func testSinglePlaceholder() {
        let vars = CmuxCommandVariableParser.variables(in: "bin/deploy --env {{environment}}")
        XCTAssertEqual(vars, [CmuxCommandVariable(name: "environment", defaultValue: nil)])
        XCTAssertTrue(CmuxCommandVariableParser.containsVariables("bin/deploy --env {{environment}}"))
    }

    func testPlaceholderWithDefault() {
        let vars = CmuxCommandVariableParser.variables(in: "bin/deploy --env {{environment=staging}}")
        XCTAssertEqual(vars, [CmuxCommandVariable(name: "environment", defaultValue: "staging")])
    }

    func testWhitespaceIsTrimmed() {
        let vars = CmuxCommandVariableParser.variables(in: "echo {{  name  }} {{ env = prod }}")
        XCTAssertEqual(
            vars,
            [
                CmuxCommandVariable(name: "name", defaultValue: nil),
                CmuxCommandVariable(name: "env", defaultValue: "prod"),
            ]
        )
    }

    func testMultipleDistinctPlaceholdersPreserveOrder() {
        let command = "bin/deploy --env {{environment}} --branch {{branch}}"
        let vars = CmuxCommandVariableParser.variables(in: command)
        XCTAssertEqual(vars.map(\.name), ["environment", "branch"])
    }

    func testDuplicatePlaceholdersAreDeduplicatedKeepingFirstDefault() {
        let command = "echo {{env=a}} && deploy {{env=b}}"
        let vars = CmuxCommandVariableParser.variables(in: command)
        XCTAssertEqual(vars, [CmuxCommandVariable(name: "env", defaultValue: "a")])
    }

    func testNameAllowsSpacesLettersDigitsAndPunctuation() {
        let vars = CmuxCommandVariableParser.variables(in: "x {{branch name}} {{RAILS_ENV}} {{my.var}}")
        XCTAssertEqual(vars.map(\.name), ["branch name", "RAILS_ENV", "my.var"])
    }

    func testEmptyPlaceholderIsIgnored() {
        XCTAssertEqual(CmuxCommandVariableParser.variables(in: "echo {{}} {{   }}"), [])
    }

    func testShellSyntaxIsNotMistakenForVariables() {
        // Names with shell-special characters keep the braces literal so
        // ordinary shell snippets are never treated as variables.
        XCTAssertEqual(CmuxCommandVariableParser.variables(in: "echo {{ $(date) }}"), [])
        XCTAssertEqual(CmuxCommandVariableParser.variables(in: "awk '{{ print $1 | sort }}'"), [])
        XCTAssertEqual(CmuxCommandVariableParser.variables(in: "echo {{1+1}}"), [])
        XCTAssertEqual(CmuxCommandVariableParser.variables(in: "echo {{a/b}}"), [])
    }

    func testNewlineInsidePlaceholderIsIgnored() {
        XCTAssertEqual(CmuxCommandVariableParser.variables(in: "echo {{na\nme}}"), [])
    }

    // MARK: Substitution

    func testSubstituteReplacesEveryOccurrence() {
        let result = CmuxCommandVariableParser.substitute(
            "echo {{x}} and {{x}}",
            values: ["x": "hi"]
        )
        XCTAssertEqual(result, "echo hi and hi")
    }

    func testSubstituteReplacesPlaceholderIncludingDefault() {
        let result = CmuxCommandVariableParser.substitute(
            "bin/deploy --env {{environment=staging}}",
            values: ["environment": "production"]
        )
        XCTAssertEqual(result, "bin/deploy --env production")
    }

    func testSubstituteLeavesUnknownPlaceholdersIntact() {
        let result = CmuxCommandVariableParser.substitute(
            "{{a}}-{{b}}",
            values: ["a": "x"]
        )
        XCTAssertEqual(result, "x-{{b}}")
    }

    func testSubstituteWithNoPlaceholdersReturnsInput() {
        XCTAssertEqual(
            CmuxCommandVariableParser.substitute("npm test", values: ["x": "y"]),
            "npm test"
        )
    }

    func testSubstitutePreservesValuesWithSpecialCharacters() {
        let result = CmuxCommandVariableParser.substitute(
            "git checkout {{branch}}",
            values: ["branch": "feature/new-thing"]
        )
        XCTAssertEqual(result, "git checkout feature/new-thing")
    }
}

// MARK: - Folder organization

final class CmuxCommandFolderTests: XCTestCase {

    private func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    func testDecodeFolderField() throws {
        let config = try decode("""
        {
          "commands": [{
            "name": "Lint modified files",
            "folder": "Project/Linting",
            "command": "bash lint.sh"
          }]
        }
        """)
        XCTAssertEqual(config.commands[0].folder, "Project/Linting")
        XCTAssertEqual(config.commands[0].folderComponents, ["Project", "Linting"])
        XCTAssertEqual(config.commands[0].folderBreadcrumb, "Project / Linting")
    }

    func testFolderComponentsTrimAndDropEmptySegments() {
        let command = CmuxCommandDefinition(
            name: "x",
            command: "echo",
            folder: "  /Project// Linting /"
        )
        XCTAssertEqual(command.folderComponents, ["Project", "Linting"])
        XCTAssertEqual(command.folderBreadcrumb, "Project / Linting")
    }

    func testNilOrBlankFolderHasNoComponents() {
        XCTAssertEqual(CmuxCommandDefinition(name: "x", command: "echo").folderComponents, [])
        XCTAssertNil(CmuxCommandDefinition(name: "x", command: "echo").folderBreadcrumb)
        let blank = CmuxCommandDefinition(name: "x", command: "echo", folder: "  //  ")
        XCTAssertEqual(blank.folderComponents, [])
        XCTAssertNil(blank.folderBreadcrumb)
    }

    @MainActor
    func testFolderSurfacesInResolvedPaletteAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-folder-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "commands": [{
            "name": "Lint modified files",
            "folder": "Project/Linting",
            "command": "bash lint.sh"
          }]
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        let action = try XCTUnwrap(
            store.paletteCustomActions().first { $0.title.contains("Lint modified files") }
        )
        XCTAssertEqual(action.folder, "Project / Linting")
        XCTAssertTrue(action.keywords.contains("Project"))
        XCTAssertTrue(action.keywords.contains("Linting"))
        XCTAssertEqual(action.subtitle, "Project / Linting")
    }
}
