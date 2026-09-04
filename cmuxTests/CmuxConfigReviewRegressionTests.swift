import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the review findings around config recovery,
/// runtime validation, shortcuts, and palette resolution.
struct CmuxConfigReviewRegressionTests {
    private func jsonObject(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    @Test func malformedActionCannotEraseDuplicateTrimmedID() {
        #expect(throws: (any Error).self) {
            try CmuxConfigFile.decodeToleratingInvalidActions(from: Data("""
            {
              "actions": {
                "  duplicate  ": { "type": "command", "command": "echo good" },
                "duplicate": {
                  "type": "workspace",
                  "workspace": {
                    "layout": {
                      "direction": "horizontal",
                      "children": [{ "pane": { "surfaces": [{ "type": "terminal" }] } }]
                    }
                  }
                }
              }
            }
            """.utf8))
        }
    }

    @Test func nonObjectActionValuesAreReportedWithoutCrashing() throws {
        let json = #"{"actions":{"scalar":"not an action"}}"#
        let result = try CmuxConfigFile.decodeToleratingInvalidActions(from: Data(json.utf8))

        #expect(result.config.actions.isEmpty)
        #expect(result.actionIssues.contains { issue in
            issue.path == "actions.scalar"
        })
    }

    @Test func tolerantDecoderFormatsNestedArrayIndices() throws {
        let json = """
        {
          "actions": {
            "bad": {
              "type": "workspace",
              "workspace": {
                "layout": {
                  "direction": "horizontal",
                  "children": [
                    { "pane": { "surfaces": [] } },
                    { "pane": { "surfaces": [{ "type": "terminal" }] } }
                  ]
                }
              }
            }
          }
        }
        """
        let result = try CmuxConfigFile.decodeToleratingInvalidActions(from: Data(json.utf8))

        #expect(result.actionIssues.contains { issue in
            issue.path.contains("children[0]")
        })
    }

    @Test func runtimeDecoderAndDoctorValidatorRejectInvalidActionValues() throws {
        let cases: [(name: String, action: String, path: String)] = [
            (
                "builtin",
                #"{ "type": "builtin", "builtin": "not-a-built-in" }"#,
                "actions.builtin.builtin"
            ),
            (
                "color",
                #"{ "type": "workspace", "workspace": { "color": "not-a-color" } }"#,
                "actions.color.workspace.color"
            ),
            (
                "shortcut",
                #"{ "type": "command", "command": "echo", "shortcut": "bare" }"#,
                "actions.shortcut.shortcut"
            ),
        ]

        for item in cases {
            let json = "{\"actions\":{\"\(item.name)\":\(item.action)}}"
            let object = try jsonObject(json)
            #expect(CmuxConfigValidator().validate(jsonObject: object).contains { issue in
                issue.path == item.path
            })

            let result = try CmuxConfigFile.decodeToleratingInvalidActions(from: Data(json.utf8))
            #expect(result.config.actions[item.name] == nil)
            #expect(result.actionIssues.contains { $0.path == item.path })
        }
    }

    @Test func runtimeOnlySurfaceButtonErrorsAreNotHiddenByStructuralValidation() throws {
        let json = #"{"surfaceTabBarButtons":[{"type":"unknown"}]}"#
        let object = try jsonObject(json)
        #expect(CmuxConfigValidator().validate(jsonObject: object).contains { issue in
            issue.path == "surfaceTabBarButtons[0].type"
        })
        #expect(throws: (any Error).self) {
            try CmuxConfigFile.decodeToleratingInvalidActions(from: Data(json.utf8))
        }
    }

    @Test func runtimeValidatorChecksRootAndUIButtonForms() throws {
        let object = try jsonObject("""
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [{ "type": "workspaceCommand" }]
            }
          },
          "surfaceTabBarButtons": [{ "target": "invalid", "icon": { "type": "unknown" } }]
        }
        """)
        let paths = Set(CmuxConfigValidator().validate(jsonObject: object).map(\.path))
        #expect(paths.contains("ui.surfaceTabBar.buttons[0]"))
        #expect(paths.contains("surfaceTabBarButtons[0].target"))
        #expect(paths.contains("surfaceTabBarButtons[0].icon.type"))
    }

    @Test func runtimeValidatorRejectsBlankSurfaceButtonIDLikeDecoder() throws {
        let json = #"{"surfaceTabBarButtons":[{"id":"   ","action":"newTerminal"}]}"#
        let object = try jsonObject(json)
        let issues = CmuxConfigValidator().validate(jsonObject: object)
        #expect(issues.contains { issue in
            issue.path == "surfaceTabBarButtons[0].id"
        })
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }

    @Test func runtimeValidatorAcceptsEveryMenuSectionOrderAlias() throws {
        let acceptedOrders = [
            "customFirst",
            "workspaceFirst",
            "newWorkspaceFirst",
            "cloudFirst",
            "cloudVMFirst",
        ]

        for order in acceptedOrders {
            let object = try jsonObject("""
            { "ui": { "newWorkspace": { "menuSectionOrder": "\(order)" } } }
            """)
            #expect(CmuxConfigValidator().validate(jsonObject: object).isEmpty)
        }

        let invalid = try jsonObject(#"{"ui":{"newWorkspace":{"menuSectionOrder":"unknown"}}}"#)
        let issue = try #require(CmuxConfigValidator().validate(jsonObject: invalid).first)
        #expect(issue.path == "ui.newWorkspace.menuSectionOrder")
        #expect(issue.message.contains("customFirst"))
        #expect(issue.message.contains("workspaceFirst"))
        #expect(issue.message.contains("newWorkspaceFirst"))
        #expect(issue.message.contains("cloudFirst"))
        #expect(issue.message.contains("cloudVMFirst"))
    }

    @Test func validatorCollectsIndependentActionAndSectionIssues() throws {
        let actionObject = try jsonObject(
            #"{"actions":{"bad":{"type":"command","command":"echo","target":"invalid","shortcut":"bare","icon":{"type":"unknown"}}}}"#
        )
        let actionPaths = Set(CmuxConfigValidator().validate(jsonObject: actionObject).map(\.path))
        #expect(actionPaths.contains("actions.bad.target"))
        #expect(actionPaths.contains("actions.bad.shortcut"))
        #expect(actionPaths.contains("actions.bad.icon.type"))

        let sectionObject = try jsonObject(#"{"actions":"not an object","commands":{}}"#)
        let sectionPaths = Set(CmuxConfigValidator().validate(jsonObject: sectionObject).map(\.path))
        #expect(sectionPaths.contains("actions"))
        #expect(sectionPaths.contains("commands"))
    }

    @Test func unmodifiedChordSecondStrokeMatchesRuntimeParser() throws {
        let json = #"{"actions":{"chord":{"type":"command","command":"echo","shortcut":["cmd+k","t"]}}}"#
        let object = try jsonObject(json)
        #expect(CmuxConfigValidator().validate(jsonObject: object).isEmpty)

        let result = try CmuxConfigFile.decodeToleratingInvalidActions(from: Data(json.utf8))
        #expect(result.actionIssues.isEmpty)
        #expect(result.config.actions["chord"]?.shortcut?.hasChord == true)
    }

    @Test func legacyPaletteNamesAndCaseMatchRuntimeResolution() throws {
        let suiteName = "cmux-config-review-palette-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["Indigo": "#123456"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#abcdef"], forKey: "workspaceTabColor.customColors")

        #expect(CmuxConfigWorkspaceColorPalette.containsName("red", defaults: defaults))
        #expect(CmuxConfigWorkspaceColorPalette.containsName(" custom 1 ", defaults: defaults))
        #expect(WorkspaceTabColorSettings.resolvedColorHex(" iNdIgO ", defaults: defaults) == "#123456")
        #expect(WorkspaceTabColorSettings.resolvedColorHex("CUSTOM 1", defaults: defaults) == "#ABCDEF")

        let config = try decode("""
        {
          "commands": [{
            "name": "palette",
            "workspace": { "color": "red" }
          }]
        }
        """.replacingOccurrences(of: "\"red\"", with: "\" custom 1 \""), colorDefaults: defaults)
        #expect(config.commands[0].workspace?.color == "#ABCDEF")
    }

    @Test func paletteResolutionUsesExactThenDeterministicCaseInsensitiveMatch() throws {
        let suiteName = "cmux-config-review-palette-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([
            "Red": "#010203",
            "red": "#040506",
        ], forKey: CmuxConfigWorkspaceColorPalette.paletteKey)

        #expect(CmuxConfigWorkspaceColorPalette.resolvedColorHex("red", defaults: defaults) == "#040506")
        for _ in 0..<10 {
            #expect(CmuxConfigWorkspaceColorPalette.resolvedColorHex("RED", defaults: defaults) == "#010203")
        }
    }

    @Test func paletteHexNormalizationRejectsSignedValues() {
        #expect(CmuxConfigWorkspaceColorPalette.normalizedHex("+ABCDEF") == nil)
        #expect(CmuxConfigWorkspaceColorPalette.normalizedHex("#+ABCDEF") == nil)
        #expect(CmuxConfigWorkspaceColorPalette.normalizedHex("abcdef") == "#ABCDEF")
    }
}

private extension CmuxConfigReviewRegressionTests {
    func decode(_ json: String, colorDefaults: UserDefaults) throws -> CmuxConfigFile {
        let decoder = JSONDecoder()
        decoder.userInfo[.cmuxWorkspaceColorDefaults] = colorDefaults
        return try decoder.decode(CmuxConfigFile.self, from: Data(json.utf8))
    }
}
