import Foundation
import Testing

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

    @Test func generatedIdentifierForTextActionIsPrefixedAndBounded() {
        let action = CmuxSurfaceTabBarButtonAction.text(
            CmuxTextActionPayload(text: String(repeating: "x", count: 200), submit: false)
        )
        #expect(action.defaultId.hasPrefix("text."))
        #expect(action.defaultId.count <= "text.".count + CmuxTextActionPayload.identifierSlugMaxLength)
    }

    // MARK: - Encoding

    @Test func textActionDefinitionRoundTripsThroughJSON() throws {
        let original = CmuxConfigActionDefinition(
            action: .text(CmuxTextActionPayload(text: "a\nb", submit: true)),
            title: "AB"
        )
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "text")
        #expect(object["text"] as? String == "a\nb")
        #expect(object["submit"] as? Bool == true)

        let decoded = try JSONDecoder().decode(CmuxConfigActionDefinition.self, from: data)
        #expect(decoded.action?.textPayload == CmuxTextActionPayload(text: "a\nb", submit: true))
        #expect(decoded.title == "AB")
    }

    // MARK: - Surface tab bar buttons

    @Test func surfaceTabBarButtonDecodesAndEncodesTextType() throws {
        let button = try JSONDecoder().decode(
            CmuxSurfaceTabBarButton.self,
            from: Data(#"{ "type": "text", "title": "Yes", "text": "y" }"#.utf8)
        )
        #expect(button.action.textPayload == CmuxTextActionPayload(text: "y", submit: false))
        #expect(button.terminalCommand == nil)
        #expect(button.id.hasPrefix("text."))

        let data = try JSONEncoder().encode(button)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "text")
        #expect(object["text"] as? String == "y")
        #expect(object["submit"] == nil)
    }
}
