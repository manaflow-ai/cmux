import Foundation
import Testing
import CmuxTextActions

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `type: "text"` actions as they flow through cmux.json: action registry
/// decoding, inference, resolution defaults, encoding, and surface tab bar
/// buttons.
struct CmuxTextActionConfigTests {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    // MARK: - Action registry decoding

    @Test func decodeExplicitTextActionKeepsMultiLineTextVerbatim() throws {
        let config = try decode("""
        {
          "actions": {
            "review-prompt": {
              "type": "text",
              "title": "Review Prompt",
              "keywords": ["review", "prompt"],
              "shortcut": "cmd+shift+r",
              "text": "Review the diff for:\\n  - regressions\\n  - missing tests\\n"
            }
          }
        }
        """)
        let definition = try #require(config.actions["review-prompt"])
        let payload = try #require(definition.action?.textPayload)
        #expect(payload.text == "Review the diff for:\n  - regressions\n  - missing tests\n")
        #expect(payload.submit == false)
        #expect(definition.shortcut != nil)
        #expect(definition.keywords == ["review", "prompt"])
        #expect(definition.action?.terminalCommand == nil)
    }

    @Test func textKeyAloneInfersTextType() throws {
        let config = try decode("""
        { "actions": { "greet": { "text": "hello", "submit": true } } }
        """)
        let payload = try #require(config.actions["greet"]?.action?.textPayload)
        #expect(payload.text == "hello")
        #expect(payload.submit == true)
    }

    @Test func blankTextActionIsRejected() {
        #expect(throws: DecodingError.self) {
            try decode(#"{ "actions": { "empty": { "type": "text", "text": " \n " } } }"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(#"{ "actions": { "missing": { "type": "text" } } }"#)
        }
    }

    // MARK: - Resolution defaults

    @Test func resolvedTextActionUsesIdAsTitleAndTextCursorIcon() throws {
        let definition = try JSONDecoder().decode(
            CmuxConfigActionDefinition.self,
            from: Data(#"{ "type": "text", "text": "ls -la" }"#.utf8)
        )
        let resolved = try #require(
            CmuxResolvedConfigAction.fromDefinition(id: "list-files", definition: definition, sourcePath: nil)
        )
        #expect(resolved.title == "list-files")
        #expect(resolved.icon == .symbol("text.cursor"))
        #expect(resolved.palette == true)
        #expect(resolved.terminalCommand == nil)
        #expect(resolved.action.textPayload?.text == "ls -la")
    }

    @Test func generatedIdentifierForTextActionIsPrefixedAndBounded() throws {
        let payload = try #require(CmuxTextActionPayload(text: String(repeating: "x", count: 200), submit: false))
        let action = CmuxSurfaceTabBarButtonAction.text(payload)
        #expect(action.defaultId.hasPrefix("text."))
        #expect(action.defaultId.count <= "text.".count + CmuxTextActionPayload.identifierSlugMaxLength)
    }

    // MARK: - Encoding

    @Test func textActionDefinitionRoundTripsThroughJSON() throws {
        let original = CmuxConfigActionDefinition(
            action: .text(try #require(CmuxTextActionPayload(text: "a\nb", submit: true))),
            title: "AB"
        )
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "text")
        #expect(object["text"] as? String == "a\nb")
        #expect(object["submit"] as? Bool == true)

        let decoded = try JSONDecoder().decode(CmuxConfigActionDefinition.self, from: data)
        #expect(decoded.action?.textPayload == (try #require(CmuxTextActionPayload(text: "a\nb", submit: true))))
        #expect(decoded.title == "AB")
    }

    // MARK: - Surface tab bar buttons

    @Test func surfaceTabBarButtonDecodesAndEncodesTextType() throws {
        let button = try JSONDecoder().decode(
            CmuxSurfaceTabBarButton.self,
            from: Data(#"{ "type": "text", "title": "Yes", "text": "y" }"#.utf8)
        )
        #expect(button.action.textPayload?.text == "y")
        #expect(button.action.textPayload?.submit == false)
        #expect(button.terminalCommand == nil)
        #expect(button.id.hasPrefix("text."))

        let data = try JSONEncoder().encode(button)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "text")
        #expect(object["text"] as? String == "y")
        #expect(object["submit"] == nil)
    }

    @Test func inlineTextButtonsSharingALongPrefixKeepDistinctGeneratedIds() throws {
        let shared = String(repeating: "x", count: CmuxTextActionPayload.identifierSlugMaxLength)
        let config = try decode("""
        { "ui": { "surfaceTabBar": { "buttons": [
            { "type": "text", "text": "\(shared) one" },
            { "type": "text", "text": "\(shared) two" },
            { "type": "text", "text": "\(shared) one", "submit": true }
        ] } } }
        """)
        let buttons = try #require(config.surfaceTabBarButtons)
        #expect(buttons.count == 3)
        #expect(Set(buttons.map(\.id)).count == 3)
    }
}

/// Project-local snippets go through the same trust gate as project
/// commands whether or not they submit: a paste with a trailing newline
/// executes in any program that has bracketed paste off. Serialized because
/// the tests share the executor's dialog override.
@Suite(.serialized)
struct CmuxTextActionTrustGateTests {
    /// Unique paths keep every descriptor untrusted without touching the
    /// user's persisted trust store; the override answers the dialog.
    private func configPaths() -> (project: String, global: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-snippet-trust-\(UUID().uuidString)", isDirectory: true)
        return (
            root.appendingPathComponent("project/cmux.json").path,
            root.appendingPathComponent("global/cmux.json").path
        )
    }

    @MainActor
    private func deliver(
        _ payload: CmuxTextActionPayload,
        confirm: Bool,
        fromProject: Bool,
        gateAnswer: Bool?,
        deliveryResult: Bool
    ) -> (result: Bool, gateConsulted: Bool, delivered: Bool) {
        let paths = configPaths()
        var gateConsulted = false
        var delivered = false
        CmuxConfigExecutor.confirmDialogOverrideForTesting = { _ in
            gateConsulted = true
            return gateAnswer ?? false
        }
        defer { CmuxConfigExecutor.confirmDialogOverrideForTesting = nil }
        let result = CmuxConfigExecutor.deliverTextActionIfAuthorized(
            payload,
            confirm: confirm,
            actionID: "probe",
            configSourcePath: fromProject ? paths.project : paths.global,
            globalConfigPath: paths.global
        ) {
            delivered = true
            return deliveryResult
        }
        return (result, gateConsulted, delivered)
    }

    @MainActor @Test func changingSubmitInvalidatesProjectSnippetTrust() throws {
        let paths = configPaths()
        var descriptors: [CmuxActionTrustDescriptor] = []
        var deliveries = 0
        CmuxConfigExecutor.confirmDialogOverrideForTesting = { descriptor in
            descriptors.append(descriptor)
            return true
        }
        defer { CmuxConfigExecutor.confirmDialogOverrideForTesting = nil }

        // Keep the explicit action ID, text, and source fixed, as when a
        // project edits only its submit flag after the user trusts a snippet.
        for submit in [false, true] {
            let payload = try #require(CmuxTextActionPayload(text: "echo snippet-ran", submit: submit))
            #expect(CmuxConfigExecutor.deliverTextActionIfAuthorized(
                payload,
                confirm: false,
                actionID: "probe",
                configSourcePath: paths.project,
                globalConfigPath: paths.global
            ) {
                deliveries += 1
                return true
            })
        }

        #expect(deliveries == 2)
        #expect(descriptors.count == 2)
        let insertOnly = try #require(descriptors.first)
        let submitting = try #require(descriptors.last)
        // The trust store keys saved permission by this fingerprint.
        #expect(insertOnly.fingerprint != submitting.fingerprint)
    }

    @MainActor @Test(arguments: [false, true])
    func untrustedProjectSnippetKeepsItsImageIconLocked(submit: Bool) throws {
        let paths = configPaths()
        let projectDirectory = URL(fileURLWithPath: paths.project).deletingLastPathComponent()
        let iconsDirectory = projectDirectory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDirectory.deletingLastPathComponent()) }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" fill="#000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: iconsDirectory.appendingPathComponent("safe.svg"))
        let payload = try #require(CmuxTextActionPayload(text: "echo snippet-ran", submit: submit))
        let button = CmuxSurfaceTabBarButton(
            id: "probe",
            icon: .imagePath("icons/safe.svg"),
            action: .text(payload)
        )
        let trusted = CmuxConfigExecutor.isTrustedSurfaceButton(
            button,
            workspaceCommand: nil,
            terminalCommandSourcePath: nil,
            surfaceTabBarConfigSourcePath: paths.project,
            globalConfigPath: paths.global
        )
        #expect(!trusted)
        #expect(button.icon?.bonsplitIcon(
            configSourcePath: paths.project,
            globalConfigPath: paths.global,
            allowProjectLocalImage: trusted
        ) == .systemImage("lock.fill"))
    }

    @MainActor @Test func insertOnlyProjectSnippetConsultsTheTrustGate() throws {
        let payload = try #require(CmuxTextActionPayload(text: "echo snippet-ran\n", submit: false))
        let outcome = deliver(payload, confirm: false, fromProject: true, gateAnswer: false, deliveryResult: true)
        #expect(outcome.gateConsulted)
        #expect(!outcome.delivered)
        #expect(!outcome.result)
    }

    @MainActor @Test func insertOnlyProjectSnippetHonoursExplicitConfirm() throws {
        let payload = try #require(CmuxTextActionPayload(text: "ls", submit: false))
        let outcome = deliver(payload, confirm: true, fromProject: true, gateAnswer: false, deliveryResult: true)
        #expect(outcome.gateConsulted)
        #expect(!outcome.delivered)
        #expect(!outcome.result)
    }

    @MainActor @Test func globalSnippetSkipsTheGateAndReportsDelivery() throws {
        let payload = try #require(CmuxTextActionPayload(text: "echo hi\n", submit: false))
        let outcome = deliver(payload, confirm: true, fromProject: false, gateAnswer: nil, deliveryResult: false)
        #expect(!outcome.gateConsulted)
        #expect(outcome.delivered)
        #expect(!outcome.result)
    }

    @MainActor @Test func projectSnippetAllowedByTheGateReportsDelivery() throws {
        let payload = try #require(CmuxTextActionPayload(text: "npm test", submit: true))
        let outcome = deliver(payload, confirm: false, fromProject: true, gateAnswer: true, deliveryResult: false)
        #expect(outcome.gateConsulted)
        #expect(outcome.delivered)
        #expect(!outcome.result)
    }
}
