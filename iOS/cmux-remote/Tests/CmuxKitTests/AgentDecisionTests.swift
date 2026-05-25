import XCTest
@testable import CmuxKit

final class AgentDecisionMapperTests: XCTestCase {

    func testMapsPermissionRequestToToolCall() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "_source": "claude",
            "_opencode_request_id": "req-1",
            "tool_name": "exec_command",
            "command": "rm -rf node_modules"
        ]
        let event = CmuxEventFrame.Event(
            bootID: "B", seq: 1, id: "B-1",
            name: "agent.hook.PermissionRequest",
            category: "agent", source: "claude", occurredAt: Date(),
            workspaceID: WorkspaceID("ws-1"),
            surfaceID: SurfaceID("sf-1"),
            paneID: nil, windowID: nil,
            payload: try JSONSerialization.data(withJSONObject: payload)
        )
        let decision = try XCTUnwrap(AgentDecisionMapper.decode(from: event))
        XCTAssertEqual(decision.id, "req-1")
        XCTAssertEqual(decision.kind, .toolCall)
        XCTAssertEqual(decision.workspaceID, WorkspaceID("ws-1"))
        XCTAssertEqual(decision.choices.map(\.id), ["allow", "allow_session", "allow_all", "allow_bypass", "deny"])
        XCTAssertEqual(decision.choices.last?.style, .destructive)
        XCTAssertTrue(decision.hasDestructiveChoice)
    }

    func testIgnoresNonAgentEvent() {
        let event = CmuxEventFrame.Event(
            bootID: "B", seq: 1, id: "B-1",
            name: "notification.created", category: "notification",
            source: "store", occurredAt: Date(),
            workspaceID: nil, surfaceID: nil, paneID: nil, windowID: nil,
            payload: Data()
        )
        XCTAssertNil(AgentDecisionMapper.decode(from: event))
    }

    func testRequiresCanonicalDecisionIdentifier() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "_source": "claude",
            "session_id": "agent-session-id",
            "tool_name": "exec_command",
            "command": "true"
        ]
        let event = CmuxEventFrame.Event(
            bootID: "B", seq: 2, id: "B-2",
            name: "agent.hook.PermissionRequest", category: "agent",
            source: "claude", occurredAt: Date(),
            workspaceID: nil, surfaceID: nil, paneID: nil, windowID: nil,
            payload: try JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertNil(AgentDecisionMapper.decode(from: event))
    }

    func testQuestionAskedRespectsCustomChoices() throws {
        let payload: [String: Any] = [
            "hook_event_name": "QuestionAsked",
            "_source": "codex",
            "request_id": "q-custom-1",
            "question": "Apply the diff?",
            "options": [
                ["id": "yes", "label": "Apply", "style": "affirmative", "requires_auth": true],
                ["id": "no", "label": "Reject", "style": "destructive"]
            ]
        ]
        let event = CmuxEventFrame.Event(
            bootID: "B", seq: 7, id: "B-7",
            name: "agent.hook.QuestionAsked", category: "agent",
            source: "codex", occurredAt: Date(),
            workspaceID: nil, surfaceID: nil, paneID: nil, windowID: nil,
            payload: try JSONSerialization.data(withJSONObject: payload)
        )
        let decision = try XCTUnwrap(AgentDecisionMapper.decode(from: event))
        XCTAssertEqual(decision.kind, .choice)
        XCTAssertEqual(decision.choices.map(\.id), ["yes", "no"])
        XCTAssertEqual(decision.choices[0].style, .affirmative)
        XCTAssertTrue(decision.choices[0].requiresAuth)
        XCTAssertEqual(decision.choices[1].style, .destructive)
    }

    func testMapsExitPlanModeToExitPlanChoices() throws {
        let payload: [String: Any] = [
            "hook_event_name": "ExitPlanMode",
            "_source": "claude",
            "_opencode_request_id": "plan-1",
            "tool_input": ["plan": "Implement the feature"]
        ]
        let event = CmuxEventFrame.Event(
            bootID: "B", seq: 8, id: "B-8",
            name: "agent.hook.ExitPlanMode", category: "agent",
            source: "claude", occurredAt: Date(),
            workspaceID: nil, surfaceID: nil, paneID: nil, windowID: nil,
            payload: try JSONSerialization.data(withJSONObject: payload)
        )
        let decision = try XCTUnwrap(AgentDecisionMapper.decode(from: event))
        XCTAssertEqual(decision.kind, .exitPlan)
        XCTAssertEqual(decision.choices.map(\.id), ["manual", "auto_accept", "ultraplan", "allow_bypass", "deny"])
        XCTAssertEqual(decision.detail, "Implement the feature")
    }

    func testMapsAskUserQuestionToolInputOptions() throws {
        let payload: [String: Any] = [
            "hook_event_name": "AskUserQuestion",
            "_source": "claude",
            "_opencode_request_id": "q-1",
            "tool_input": [
                "questions": [
                    [
                        "prompt": "Pick a target",
                        "options": [
                            ["id": "ios", "label": "iOS"],
                            ["id": "ipad", "label": "iPadOS"]
                        ]
                    ]
                ]
            ]
        ]
        let event = CmuxEventFrame.Event(
            bootID: "B", seq: 9, id: "B-9",
            name: "agent.hook.AskUserQuestion", category: "agent",
            source: "claude", occurredAt: Date(),
            workspaceID: nil, surfaceID: nil, paneID: nil, windowID: nil,
            payload: try JSONSerialization.data(withJSONObject: payload)
        )
        let decision = try XCTUnwrap(AgentDecisionMapper.decode(from: event))
        XCTAssertEqual(decision.kind, .choice)
        XCTAssertEqual(decision.summary, "Pick a target")
        XCTAssertEqual(decision.choices.map(\.label), ["iOS", "iPadOS"])
    }
}

final class TerminalInputAssistTests: XCTestCase {
    func testCtrlAEncodesAsSOH() {
        let out = ModifierEncoder.encode(character: "a", ctrl: true, alt: false)
        XCTAssertEqual(out, "\u{01}")
    }

    func testCtrlUpperALowercaseSame() {
        XCTAssertEqual(
            ModifierEncoder.encode(character: "A", ctrl: true, alt: false),
            ModifierEncoder.encode(character: "a", ctrl: true, alt: false)
        )
    }

    func testAltPrefixesEscape() {
        XCTAssertEqual(ModifierEncoder.encode(character: "f", ctrl: false, alt: true), "\u{1B}f")
    }

    func testCtrlAltCombined() {
        // Ctrl-Alt-A = ESC + 0x01
        XCTAssertEqual(ModifierEncoder.encode(character: "a", ctrl: true, alt: true), "\u{1B}\u{01}")
    }

    func testSmartPasteRemovesCurlyQuotes() {
        let raw = "echo \u{201C}hello\u{201D}"
        let result = SmartPasteSanitiser.sanitise(raw)
        XCTAssertEqual(result.cleaned, "echo \"hello\"")
        XCTAssertTrue(result.didStripSmartQuotes)
    }

    func testSmartPasteNormalisesCRLF() {
        let raw = "line1\r\nline2\r\n"
        let result = SmartPasteSanitiser.sanitise(raw)
        XCTAssertTrue(result.didNormaliseNewlines)
        XCTAssertEqual(result.cleaned, "line1\nline2\n")
        XCTAssertTrue(result.isMultiLine)
    }

    func testSmartPasteSingleLineUnchanged() {
        let result = SmartPasteSanitiser.sanitise("plain text")
        XCTAssertFalse(result.isMultiLine)
        XCTAssertFalse(result.didStripSmartQuotes)
    }
}
