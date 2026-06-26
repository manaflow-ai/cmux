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

    func testUnquotedNonIdentifierIsRejected() {
        // At an unquoted position, only bare identifiers are variables; shell
        // snippets and template expressions keep the braces literal.
        XCTAssertEqual(variables("echo {{ $(date) }}"), [])
        XCTAssertEqual(variables("echo {{1+1}}"), [])
        XCTAssertEqual(variables("echo {{a/b}}"), [])
        XCTAssertEqual(variables("gomplate -i {{ .Env.FOO }}"), [])
        XCTAssertEqual(variables("echo {{ name | upper }}"), [])
    }

    func testQuotedPlaceholdersAreLeftLiteral() {
        // A placeholder inside single or double quotes is template text, not a
        // cmux variable, so existing quoted template commands run unchanged.
        XCTAssertEqual(variables("helm --set-template '{{tag}}'"), [])
        XCTAssertEqual(variables("echo \"{{x}}\""), [])
        XCTAssertEqual(variables("gomplate -i '{{ .Env.FOO }}'"), [])
        // Even when the author wraps a bare identifier in quotes it is not
        // intercepted (and therefore cannot be unsafely re-quoted).
        XCTAssertEqual(variables("deploy '{{branch}}'"), [])
        XCTAssertEqual(substitute("helm --set-template '{{tag}}'", ["tag": "v1"]),
                       "helm --set-template '{{tag}}'")
        XCTAssertEqual(substitute("deploy '{{branch}}'", ["branch": "main; rm -rf /"]),
                       "deploy '{{branch}}'")
    }

    func testMixedQuotedAndUnquotedOccurrences() {
        // Only the unquoted occurrence is a variable; the quoted one stays literal.
        let command = "deploy {{env}} --label '{{env}}'"
        XCTAssertEqual(variables(command).map(\.name), ["env"])
        XCTAssertEqual(substitute(command, ["env": "prod"]),
                       "deploy 'prod' --label '{{env}}'")
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
