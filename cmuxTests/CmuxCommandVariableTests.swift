import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Variable parsing

final class CmuxCommandTemplateTests: XCTestCase {

    private func variables(_ command: String) -> [CmuxCommandVariable] {
        CmuxCommandTemplate(rawValue: command).variables
    }

    private func substitute(_ command: String, _ values: [String: String]) -> String {
        CmuxCommandTemplate(rawValue: command).substituting(values)
    }

    func testNoPlaceholdersReturnsEmpty() {
        XCTAssertEqual(variables("npm test"), [])
        XCTAssertFalse(CmuxCommandTemplate(rawValue: "npm test").containsVariables)
    }

    func testSinglePlaceholder() {
        XCTAssertEqual(variables("bin/deploy --env {{environment}}"),
                       [CmuxCommandVariable(name: "environment", defaultValue: nil)])
        XCTAssertTrue(CmuxCommandTemplate(rawValue: "bin/deploy --env {{environment}}").containsVariables)
    }

    func testPlaceholderWithDefault() {
        XCTAssertEqual(variables("bin/deploy --env {{environment=staging}}"),
                       [CmuxCommandVariable(name: "environment", defaultValue: "staging")])
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(
            variables("echo {{  name  }} {{ env = prod }}"),
            [
                CmuxCommandVariable(name: "name", defaultValue: nil),
                CmuxCommandVariable(name: "env", defaultValue: "prod"),
            ]
        )
    }

    func testMultipleDistinctPlaceholdersPreserveOrder() {
        XCTAssertEqual(variables("bin/deploy --env {{environment}} --branch {{branch}}").map(\.name),
                       ["environment", "branch"])
    }

    func testDuplicatePlaceholdersAreDeduplicatedKeepingFirstDefault() {
        XCTAssertEqual(variables("echo {{env=a}} && deploy {{env=b}}"),
                       [CmuxCommandVariable(name: "env", defaultValue: "a")])
    }

    func testNameAllowsBareIdentifiers() {
        XCTAssertEqual(variables("x {{branch_name}} {{RAILS_ENV}} {{my-var}}").map(\.name),
                       ["branch_name", "RAILS_ENV", "my-var"])
    }

    func testEmptyPlaceholderIsIgnored() {
        XCTAssertEqual(variables("echo {{}} {{   }}"), [])
    }

    func testShellSyntaxIsNotMistakenForVariables() {
        // Names with shell-special characters keep the braces literal so
        // ordinary shell snippets are never treated as variables.
        XCTAssertEqual(variables("echo {{ $(date) }}"), [])
        XCTAssertEqual(variables("awk '{{ print $1 | sort }}'"), [])
        XCTAssertEqual(variables("echo {{1+1}}"), [])
        XCTAssertEqual(variables("echo {{a/b}}"), [])
    }

    func testTemplateExpressionsAreLeftUntouched() {
        // Go/Handlebars-style templates (leading dot, internal spaces, pipes,
        // functions) must not be mistaken for cmux variables, so existing
        // templated shell commands keep running unchanged.
        XCTAssertEqual(variables("gomplate -i '{{ .Env.FOO }}'"), [])
        XCTAssertEqual(variables("echo '{{ range .Items }}'"), [])
        XCTAssertEqual(variables("echo '{{ name | upper }}'"), [])
        XCTAssertEqual(variables("echo '{{.value}}'"), [])
        XCTAssertEqual(substitute("gomplate -i '{{ .Env.FOO }}'", ["FOO": "x"]),
                       "gomplate -i '{{ .Env.FOO }}'")
    }

    func testBackslashEscapeProducesLiteralBraces() {
        // `\{{name}}` is not a variable and the backslash is stripped on run.
        XCTAssertEqual(variables("echo \\{{name}}"), [])
        XCTAssertEqual(substitute("echo \\{{name}}", [:]), "echo {{name}}")
        // An escaped and an unescaped occurrence can coexist; only the real
        // variable is substituted (and shell-quoted).
        let mixed = "echo \\{{env}} {{env}}"
        XCTAssertEqual(variables(mixed).map(\.name), ["env"])
        XCTAssertEqual(substitute(mixed, ["env": "prod"]), "echo {{env}} 'prod'")
    }

    func testNewlineInsidePlaceholderIsIgnored() {
        XCTAssertEqual(variables("echo {{na\nme}}"), [])
    }

    // MARK: Substitution

    func testSubstituteShellQuotesEveryOccurrence() {
        XCTAssertEqual(substitute("echo {{x}} and {{x}}", ["x": "hi"]), "echo 'hi' and 'hi'")
    }

    func testSubstituteReplacesPlaceholderIncludingDefault() {
        XCTAssertEqual(substitute("bin/deploy --env {{environment=staging}}", ["environment": "production"]),
                       "bin/deploy --env 'production'")
    }

    func testSubstituteLeavesUnknownPlaceholdersIntact() {
        XCTAssertEqual(substitute("{{a}}-{{b}}", ["a": "x"]), "'x'-{{b}}")
    }

    func testSubstituteWithNoPlaceholdersReturnsInput() {
        XCTAssertEqual(substitute("npm test", ["x": "y"]), "npm test")
    }

    func testSubstitutePreservesValuesWithSpecialCharacters() {
        XCTAssertEqual(substitute("git checkout {{branch}}", ["branch": "feature/new-thing"]),
                       "git checkout 'feature/new-thing'")
    }

    func testSubstituteNeutralizesShellMetacharacters() {
        // A value with shell metacharacters is passed as one literal argument,
        // never as separate shell words.
        XCTAssertEqual(substitute("git checkout {{branch}}", ["branch": "main; rm -rf /"]),
                       "git checkout 'main; rm -rf /'")
    }

    func testShellQuoteEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(CmuxCommandTemplate.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(CmuxCommandTemplate.shellQuote(""), "''")
        XCTAssertEqual(CmuxCommandTemplate.shellQuote("plain"), "'plain'")
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
