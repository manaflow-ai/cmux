import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxConfigLayoutEntryTests: XCTestCase {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    func testDecodeCommandsWithLayoutOnlyCommandAndMixedEntries() throws {
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
        XCTAssertEqual(config.commands.count, 3)
        XCTAssertEqual(config.commands[0].name, "Saved layout")
        XCTAssertNil(config.commands[0].command)
        XCTAssertEqual(config.commands[0].workspace?.cwd, "/tmp/layout")
        XCTAssertEqual(config.commands[0].workspace?.color, "#336699")
        XCTAssertNotNil(config.commands[0].workspace?.layout)
        XCTAssertEqual(config.commands[1].name, "Run tests")
        XCTAssertEqual(config.commands[1].command, "npm test")
        XCTAssertNil(config.commands[1].workspace)
        XCTAssertEqual(config.commands[2].name, "Command with layout metadata")
        XCTAssertEqual(config.commands[2].command, "echo mixed")
        XCTAssertNil(config.commands[2].workspace)
    }

    func testDecodeCommandsKeepsValidEntriesWhenOneEntryIsMalformed() throws {
        let config = try decode("""
        { "commands": [{ "name": "broken" }, { "name": "survives", "command": "echo survives" }] }
        """)
        XCTAssertEqual(config.commands.map(\.name), ["survives"])
        XCTAssertEqual(config.commandDecodingIssues.count, 1)
        XCTAssertEqual(config.commandDecodingIssues[0].path, "commands[0]")
    }

    func testCommandDefinitionUsesExplicitSumTypeCases() throws {
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
            XCTFail("Expected layout command variant")
        }
        if case .command = command {
        } else {
            XCTFail("Expected shell command variant")
        }
    }

    func testDecodeFlattenedLayoutNormalizesLegacySingleChildSplit() throws {
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
        let layout = try XCTUnwrap(config.commands.first?.workspace?.layout)
        if case .pane = layout {
        } else {
            XCTFail("Expected the legacy single-child split to normalize to a pane")
        }
    }

    func testDecodeMalformedCommandEntryIsSkippedAndReported() throws {
        let config = try decode("""
        { "commands": [{ "name": "bad", "command": "   " }, { "name": "ok", "command": "echo ok" }] }
        """)
        XCTAssertEqual(config.commands.map(\.name), ["ok"])
        XCTAssertEqual(config.commandDecodingIssues.count, 1)
        XCTAssertTrue(config.commandDecodingIssues[0].description.contains("command"))
    }

    func testDecodeMalformedEntriesAreSkippedWithoutBlockingTheFile() throws {
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
            XCTAssertTrue(config.commands.isEmpty, fixture)
            XCTAssertEqual(config.commandDecodingIssues.count, 1, fixture)
        }
    }

    func testDecodeHybridEntryUsesCommandVariant() throws {
        let config = try decode(#"{"commands":[{"name":"hybrid","command":"echo hi","workspace":{"name":"ws"}}]}"#)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].command, "echo hi")
        XCTAssertNil(config.commands[0].workspace)
    }
}
