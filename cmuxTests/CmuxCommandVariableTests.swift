import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Variable parsing

@Suite struct CmuxCommandTemplateTests {

    private func variables(_ command: String) -> [CmuxCommandVariable] {
        CmuxCommandTemplate(rawValue: command).variables
    }

    private func substitute(_ command: String, _ values: [String: String]) -> String {
        CmuxCommandTemplate(rawValue: command).substituting(values)
    }

    @Test func noPlaceholdersReturnsEmpty() {
        #expect(variables("npm test").isEmpty)
        #expect(!CmuxCommandTemplate(rawValue: "npm test").containsVariables)
    }

    @Test func singlePlaceholder() {
        #expect(variables("bin/deploy --env {{environment}}")
            == [CmuxCommandVariable(name: "environment", defaultValue: nil)])
        #expect(CmuxCommandTemplate(rawValue: "bin/deploy --env {{environment}}").containsVariables)
    }

    @Test func placeholderWithDefault() {
        #expect(variables("bin/deploy --env {{environment=staging}}")
            == [CmuxCommandVariable(name: "environment", defaultValue: "staging")])
    }

    @Test func whitespaceIsTrimmed() {
        #expect(
            variables("echo {{  name  }} {{ env = prod }}")
                == [
                    CmuxCommandVariable(name: "name", defaultValue: nil),
                    CmuxCommandVariable(name: "env", defaultValue: "prod"),
                ]
        )
    }

    @Test func multipleDistinctPlaceholdersPreserveOrder() {
        #expect(variables("bin/deploy --env {{environment}} --branch {{branch}}").map(\.name)
            == ["environment", "branch"])
    }

    @Test func duplicatePlaceholdersAreDeduplicatedKeepingFirstDefault() {
        #expect(variables("echo {{env=a}} && deploy {{env=b}}")
            == [CmuxCommandVariable(name: "env", defaultValue: "a")])
    }

    @Test func nameAllowsBareIdentifiers() {
        #expect(variables("x {{branch_name}} {{RAILS_ENV}} {{my-var}}").map(\.name)
            == ["branch_name", "RAILS_ENV", "my-var"])
    }

    @Test func emptyPlaceholderIsIgnored() {
        #expect(variables("echo {{}} {{   }}").isEmpty)
    }

    @Test func unquotedNonIdentifierIsRejected() {
        // At an unquoted position, only bare identifiers are variables; shell
        // snippets and template expressions keep the braces literal.
        #expect(variables("echo {{ $(date) }}").isEmpty)
        #expect(variables("echo {{1+1}}").isEmpty)
        #expect(variables("echo {{a/b}}").isEmpty)
        #expect(variables("gomplate -i {{ .Env.FOO }}").isEmpty)
        #expect(variables("echo {{ name | upper }}").isEmpty)
    }

    @Test func quotedPlaceholdersAreLeftLiteral() {
        // A placeholder inside single or double quotes is template text, not a
        // cmux variable, so existing quoted template commands run unchanged.
        #expect(variables("helm --set-template '{{tag}}'").isEmpty)
        #expect(variables("echo \"{{x}}\"").isEmpty)
        #expect(variables("gomplate -i '{{ .Env.FOO }}'").isEmpty)
        // Even when the author wraps a bare identifier in quotes it is not
        // intercepted (and therefore cannot be unsafely re-quoted).
        #expect(variables("deploy '{{branch}}'").isEmpty)
        #expect(substitute("helm --set-template '{{tag}}'", ["tag": "v1"])
            == "helm --set-template '{{tag}}'")
        #expect(substitute("deploy '{{branch}}'", ["branch": "main; rm -rf /"])
            == "deploy '{{branch}}'")
    }

    @Test func mixedQuotedAndUnquotedOccurrences() {
        // Only the unquoted occurrence is a variable; the quoted one stays literal.
        let command = "deploy {{env}} --label '{{env}}'"
        #expect(variables(command).map(\.name) == ["env"])
        #expect(substitute(command, ["env": "prod"]) == "deploy 'prod' --label '{{env}}'")
    }

    @Test func escapedQuoteKeepsPlaceholderQuoted() {
        // A backslash-escaped quote does not close the surrounding quote, so a
        // placeholder after it is still quoted and must not be substituted.
        let command = "echo \"prefix \\\" {{branch}} suffix\""
        #expect(variables(command).isEmpty)
        #expect(substitute(command, ["branch": "$(touch /tmp/pwn)"]) == command)
        // After the double-quoted span closes, an unquoted placeholder is a variable.
        #expect(variables("echo \"a \\\" b\" {{env}}").map(\.name) == ["env"])
    }

    @Test func newlineInsidePlaceholderIsIgnored() {
        #expect(variables("echo {{na\nme}}").isEmpty)
    }

    @Test func heredocBodiesAreLeftLiteral() {
        // Template text inside a here-doc body is not a shell word, so existing
        // commands that embed templates via heredocs run unchanged.
        #expect(variables("cat >t <<'EOF'\n{{name}}\nEOF").isEmpty)
        #expect(substitute("cat <<EOF\n{{name}}\nEOF", ["name": "x"]) == "cat <<EOF\n{{name}}\nEOF")
        #expect(variables("cat <<-EOF\n\t{{name}}\n\tEOF").isEmpty)
        // A variable before the body is still substituted; the body is skipped.
        #expect(variables("grep {{pat}} <<EOF\n{{body}}\nEOF").map(\.name) == ["pat"])
        // Scanning resumes after the terminator line.
        #expect(variables("cat <<EOF\n{{body}}\nEOF\necho {{after}}").map(\.name) == ["after"])
        // `<<<` is a here-string, not a here-doc: its word is a normal shell word.
        #expect(variables("cmd <<< {{x}}").map(\.name) == ["x"])
    }

    @Test func commentsAreLeftLiteral() {
        #expect(variables("echo {{x}} # comment with {{y}}").map(\.name) == ["x"])
        #expect(variables("# {{whole}} line comment").isEmpty)
        // `#` mid-word is not a comment.
        #expect(variables("echo abc#{{notcomment}}").map(\.name) == ["notcomment"])
    }

    // MARK: Substitution

    @Test func substituteShellQuotesEveryOccurrence() {
        #expect(substitute("echo {{x}} and {{x}}", ["x": "hi"]) == "echo 'hi' and 'hi'")
    }

    @Test func substituteReplacesPlaceholderIncludingDefault() {
        #expect(substitute("bin/deploy --env {{environment=staging}}", ["environment": "production"])
            == "bin/deploy --env 'production'")
    }

    @Test func substituteLeavesUnknownPlaceholdersIntact() {
        #expect(substitute("{{a}}-{{b}}", ["a": "x"]) == "'x'-{{b}}")
    }

    @Test func substituteWithNoPlaceholdersReturnsInput() {
        #expect(substitute("npm test", ["x": "y"]) == "npm test")
    }

    @Test func substitutePreservesValuesWithSpecialCharacters() {
        #expect(substitute("git checkout {{branch}}", ["branch": "feature/new-thing"])
            == "git checkout 'feature/new-thing'")
    }

    @Test func substituteNeutralizesShellMetacharacters() {
        // A value with shell metacharacters is passed as one literal argument,
        // never as separate shell words.
        #expect(substitute("git checkout {{branch}}", ["branch": "main; rm -rf /"])
            == "git checkout 'main; rm -rf /'")
    }

    @Test func shellQuoteEscapesEmbeddedSingleQuotes() {
        #expect(CmuxCommandTemplate.shellQuote("it's") == "'it'\\''s'")
        #expect(CmuxCommandTemplate.shellQuote("") == "''")
        #expect(CmuxCommandTemplate.shellQuote("plain") == "'plain'")
    }

    @Test func shellQuoteStripsTerminalControlCharacters() {
        // The resolved command is sent as interactive terminal input, so
        // line-editor control bytes (Ctrl-U, newline, ESC, DEL) must be removed
        // from values — quoting alone does not stop the line editor.
        #expect(CmuxCommandTemplate.shellQuote("a\u{15}b") == "'ab'")
        #expect(CmuxCommandTemplate.shellQuote("x\ny") == "'xy'")
        #expect(CmuxCommandTemplate.shellQuote("e\u{1B}[31m") == "'e[31m'")
        #expect(CmuxCommandTemplate.shellQuote("\u{7F}del") == "'del'")
        // The Ctrl-U "clear line" injection is neutralized end-to-end.
        #expect(substitute("git checkout {{branch}}", ["branch": "\u{15}rm -rf ~ #"])
            == "git checkout 'rm -rf ~ #'")
    }
}

// MARK: - Folder organization

@MainActor
@Suite struct CmuxCommandFolderTests {

    private func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    @Test func decodeFolderField() throws {
        let config = try decode("""
        {
          "commands": [{
            "name": "Lint modified files",
            "folder": "Project/Linting",
            "command": "bash lint.sh"
          }]
        }
        """)
        #expect(config.commands[0].folder == "Project/Linting")
        #expect(config.commands[0].folderComponents == ["Project", "Linting"])
        #expect(config.commands[0].folderBreadcrumb == "Project / Linting")
    }

    @Test func folderComponentsTrimAndDropEmptySegments() {
        let command = CmuxCommandDefinition(
            name: "x",
            command: "echo",
            folder: "  /Project// Linting /"
        )
        #expect(command.folderComponents == ["Project", "Linting"])
        #expect(command.folderBreadcrumb == "Project / Linting")
    }

    @Test func nilOrBlankFolderHasNoComponents() {
        #expect(CmuxCommandDefinition(name: "x", command: "echo").folderComponents.isEmpty)
        #expect(CmuxCommandDefinition(name: "x", command: "echo").folderBreadcrumb == nil)
        let blank = CmuxCommandDefinition(name: "x", command: "echo", folder: "  //  ")
        #expect(blank.folderComponents.isEmpty)
        #expect(blank.folderBreadcrumb == nil)
    }

    @Test func folderSurfacesInResolvedPaletteAction() throws {
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

        let action = try #require(
            store.paletteCustomActions().first { $0.title.contains("Lint modified files") }
        )
        #expect(action.folder == "Project / Linting")
        #expect(action.keywords.contains("Project"))
        #expect(action.keywords.contains("Linting"))
        #expect(action.subtitle == "Project / Linting")
    }
}
