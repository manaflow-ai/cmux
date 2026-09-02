import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CmuxConfigLayoutEntryTests {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    @Test func decodeCommandsWithLayoutOnlyCommandAndMixedEntries() throws {
        let json = """
        {
          "commands": [
            {
              "name": "Saved layout",
              "cwd": "/tmp/layout",
              "color": "#336699",
              "layout": {
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal", "name": "left" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal", "name": "right" }] } }
                ]
              }
            },
            { "name": "Run tests", "command": "npm test" },
            {
              "name": "Command with layout metadata",
              "command": "echo mixed",
              "cwd": "/tmp/mixed",
              "layout": {}
            }
          ]
        }
        """

        let config = try decode(json)
        #expect(config.commands.count == 3)
        #expect(config.commands[0].name == "Saved layout")
        #expect(config.commands[0].command == nil)
        #expect(config.commands[0].workspace?.cwd == "/tmp/layout")
        #expect(config.commands[0].workspace?.color == "#336699")
        #expect(config.commands[0].workspace?.layout != nil)
        #expect(config.commands[1].name == "Run tests")
        #expect(config.commands[1].command == "npm test")
        #expect(config.commands[1].workspace == nil)
        #expect(config.commands[2].name == "Command with layout metadata")
        #expect(config.commands[2].command == "echo mixed")
        #expect(config.commands[2].workspace == nil)
    }

    @Test func decodeCommandsKeepsValidEntriesWhenOneEntryIsMalformed() throws {
        let config = try decode("""
        { "commands": [{ "name": "broken" }, { "name": "survives", "command": "echo survives" }] }
        """)
        #expect(config.commands.map(\.name) == ["survives"])
        #expect(config.commandDecodingIssues.count == 1)
        #expect(config.commandDecodingIssues[0].path == "commands[0]")
    }

    @Test func commandDefinitionUsesExplicitSumTypeCases() throws {
        let layout = try JSONDecoder().decode(
            CmuxCommandDefinition.self,
            from: Data(#"{ "name": "layout", "cwd": "/tmp", "layout": { "pane": { "surfaces": [{ "type": "terminal" }] } } }"#.utf8)
        )
        let command = try JSONDecoder().decode(
            CmuxCommandDefinition.self,
            from: Data(#"{ "name": "command", "command": "echo command" }"#.utf8)
        )
        if case .layout = layout {
        } else {
            Issue.record("Expected layout command variant")
        }
        if case .command = command {
        } else {
            Issue.record("Expected shell command variant")
        }
    }

    @Test func decodeFlattenedLayoutNormalizesLegacySingleChildSplit() throws {
        let config = try decode("""
        {
          "commands": [{
            "name": "legacy layout",
            "cwd": "/tmp",
            "layout": {
              "direction": "horizontal",
              "children": [{ "pane": { "surfaces": [{ "type": "terminal" }] } }]
            }
          }]
        }
        """)
        let layout = try #require(config.commands.first?.workspace?.layout)
        if case .pane = layout {
        } else {
            Issue.record("Expected the legacy single-child split to normalize to a pane")
        }
    }

    @Test func decodeMalformedCommandEntryIsSkippedAndReported() throws {
        let config = try decode("""
        { "commands": [{ "name": "bad", "command": "   " }, { "name": "ok", "command": "echo ok" }] }
        """)
        #expect(config.commands.map(\.name) == ["ok"])
        #expect(config.commandDecodingIssues.count == 1)
        #expect(config.commandDecodingIssues[0].description.contains("command"))
    }

    @Test func decodeMalformedEntriesAreSkippedWithoutBlockingTheFile() throws {
        let fixtures = [
            #"{"commands":[{"name":"bad","workspace":{"layout":{"invalid":true}}}]}"#,
            #"{"commands":[{"name":"bad","workspace":{"layout":{"pane":{"surfaces":[{"type":"invalid"}]}}}}]}"#,
            #"{"commands":[{"name":"bad"}]}"#,
            #"{"commands":[{"name":"bad","workspace":{"layout":{"pane":{"surfaces":[{"type":"terminal"}]}},"direction":"horizontal"}}]}"#,
            #"{"commands":[{"name":"bad","workspace":{"layout":{"direction":"horizontal","children":[{"pane":{"surfaces":[{"type":"terminal"}]}}]}}}]}"#,
            #"{"commands":[{"name":"bad","workspace":{"layout":{"direction":"vertical","children":[{"pane":{"surfaces":[{"type":"terminal"}]}},{"pane":{"surfaces":[{"type":"terminal"}]}},{"pane":{"surfaces":[{"type":"terminal"}]}}]}}}]}"#,
            #"{"commands":[{"name":"bad","workspace":{"layout":{"pane":{"surfaces":[]}}}}]}"#,
            #"{"commands":[{"name":"","command":"echo hi"}]}"#,
            #"{"commands":[{"name":"   ","command":"echo hi"}]}"#,
            #"{"commands":[{"name":"bad","command":""}]}"#,
            #"{"commands":[{"name":"bad","command":"   "}]}"#,
        ]

        for fixture in fixtures {
            let config = try decode(fixture)
            #expect(config.commands.isEmpty, Comment(rawValue: fixture))
            #expect(config.commandDecodingIssues.count == 1, Comment(rawValue: fixture))
        }
    }

    @Test func decodeHybridEntryUsesCommandVariant() throws {
        let config = try decode(#"{"commands":[{"name":"hybrid","command":"echo hi","workspace":{"name":"ws"}}]}"#)
        #expect(config.commands.count == 1)
        #expect(config.commands[0].command == "echo hi")
        #expect(config.commands[0].workspace == nil)
    }

    @Test func decodeNullCommandsAsEmptyList() throws {
        let config = try decode(#"{"commands":null}"#)
        #expect(config.commands.isEmpty)
        #expect(config.commandDecodingIssues.isEmpty)
    }

    @Test func typeValidatorRejectsBooleanSplitValue() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"commands":[{"name":"bad","layout":{"direction":"horizontal","split":true,"children":[{"pane":{"surfaces":[{"type":"terminal"}]}},{"pane":{"surfaces":[{"type":"terminal"}]}}]}}]}"#.utf8)
        )
        let issues = CmuxConfigTypeValidator().issues(in: object)
        #expect(issues.contains { $0.path == "commands[0].layout.split" })
    }

    @Test func typeValidatorMatchesRuntimeColorNormalization() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"commands":[{"name":"layout","color":"  #336699  ","layout":{"pane":{"surfaces":[{"type":"terminal"}]}}}]}"#.utf8)
        )
        #expect(CmuxConfigTypeValidator().issues(in: object).isEmpty)
    }

    @Test func decodeAndValidateMatchesCaseInsensitiveNamedColorResolution() throws {
        let data = Data(#"{"commands":[{"name":"layout","color":"  indigo  ","layout":{"pane":{"surfaces":[{"type":"terminal"}]}}}]}"#.utf8)
        let decoded = try CmuxConfigFile.decodeAndValidate(
            sanitizedData: data,
            workspaceColorPalette: ["Indigo": "#283593"]
        )
        #expect(decoded.config.commands.count == 1)
        #expect(decoded.config.commands[0].workspace?.color == "#283593")
        #expect(decoded.typeIssues.isEmpty)
    }

    @Test func typeValidatorUsesUnambiguousCountDiagnostic() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"commands":[{"name":"empty-pane","layout":{"pane":{"surfaces":[]}}}]}"#.utf8)
        )
        let issue = try #require(CmuxConfigTypeValidator().issues(in: object).first)
        #expect(issue.path == "commands[0].layout.pane.surfaces")
        #expect(!issue.message.contains("item(s)"))
        #expect(!issue.message.isEmpty)
    }

    @Test func typeValidatorRejectsLegacyOverrideNamesRuntimeDiscards() throws {
        let suiteName = "cmux-config-validator-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["Not A Builtin": "#336699"], forKey: "workspaceTabColor.defaultOverrides")
        let object = try JSONSerialization.jsonObject(
            with: Data(#"{"commands":[{"name":"layout","color":"Not A Builtin","layout":{"pane":{"surfaces":[{"type":"terminal"}]}}}]}"#.utf8)
        )
        let names = CmuxConfigTypeValidator.workspaceColorNames(from: defaults)
        let issues = CmuxConfigTypeValidator(workspaceColorNames: names).issues(in: object)
        #expect(issues.contains { $0.path == "commands[0].color" })
    }

    @Test func programmaticCommandInitializerRejectsInvalidDefinitions() {
        #expect(CmuxCommandDefinition(name: "missing") == nil)
        #expect(CmuxCommandDefinition(name: "blank", command: "  ") == nil)
        #expect(CmuxCommandDefinition(name: "", command: "echo") == nil)
        #expect(CmuxShellCommandDefinition(name: "shell", command: "") == nil)
        #expect(
            CmuxWorkspaceLayoutCommandDefinition(
                name: "",
                workspace: CmuxWorkspaceDefinition()
            ) == nil
        )
    }

    @Test func failureLogGateClaimsEachRevisionOnce() {
        let gate = CmuxConfigDecodeFailureLogGate()
        #expect(gate.claim(path: "/tmp/config.json", key: "same-revision"))
        #expect(!gate.claim(path: "/tmp/config.json", key: "same-revision"))
        #expect(gate.claim(path: "/tmp/config.json", key: "new-revision"))
        #expect(gate.claim(path: "/tmp/other.json", key: "same-revision"))
        #expect(!gate.claim(path: "/tmp/config.json", key: "same-revision"))
    }

    @Test func decodeCacheClaimsColdRevisionOnlyOnce() {
        let cache = CmuxConfigDecodeCache(countLimit: 2)
        switch cache.lookupOrClaim("revision") {
        case .miss(let isFirstLoader):
            #expect(isFirstLoader)
        case .hit:
            Issue.record("Expected the first lookup to claim the cold revision")
        }
        switch cache.lookupOrClaim("revision") {
        case .miss(let isFirstLoader):
            #expect(!isFirstLoader)
        case .hit:
            Issue.record("Expected the in-flight revision to remain a miss")
        }
        cache.finishLoading("revision", isOwner: false)
        switch cache.lookupOrClaim("revision") {
        case .miss(let isFirstLoader):
            #expect(!isFirstLoader)
        case .hit:
            Issue.record("A follower must not release the owner's in-flight claim")
        }
        cache.insert(config: nil, for: "revision")
        cache.finishLoading("revision", isOwner: true)
        switch cache.lookupOrClaim("revision") {
        case .hit(let entry):
            #expect(entry.config == nil)
        case .miss:
            Issue.record("Expected the cached failure to be reused")
        }
    }

    @Test func typeIssueDiagnosticsRemoveNewlinesAndBidiControls() {
        let issue = CmuxConfigTypeIssue(path: "commands[0]", message: "bad\nvalue\u{202E}tail")
        #expect(issue.description == "commands[0]: bad valuetail")
    }
}
