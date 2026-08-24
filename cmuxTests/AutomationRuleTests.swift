import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Automation rules")
struct AutomationRuleTests {
    @Test("decodes the v1 example and matches event predicates")
    func decodesWorkedSchemaAndMatches() throws {
        let json = #"""
        {
          "version": 1,
          "rules": [
            {
              "id": "surface-needs-input",
              "when": { "event": "agent.needs_input" },
              "where": { "workspace.tag": "dispatch", "surface.kind": "terminal" },
              "then": [
                { "action": "notify", "title": "Agent needs input" },
                { "action": "rpc", "method": "workspace.reorder", "params": { "index": 1 } }
              ]
            }
          ]
        }
        """#
        let configuration = try JSONDecoder().decode(
            AutomationConfiguration.self,
            from: Data(json.utf8)
        )
        let rule = try #require(configuration.rules.first)
        #expect(rule.id == "surface-needs-input")
        #expect(
            rule.matches(
                event: [
                    "name": "agent.needs_input",
                    "category": "agent",
                    "payload": [
                        "workspace_tag": "dispatch",
                        "kind": "terminal"
                    ]
                ]
            )
        )
        #expect(
            !rule.matches(
                event: [
                    "name": "agent.needs_input",
                    "payload": [
                        "workspace_tag": "other",
                        "kind": "terminal"
                    ]
                ]
            )
        )
    }

    @Test("configuration writes and reloads atomically")
    func configurationRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationConfigStore(
            fileURL: directory.appendingPathComponent("automations.json")
        )
        let configuration = AutomationConfiguration(
            rules: [
                AutomationRule(
                    id: "one",
                    when: AutomationWhen(category: "workspace"),
                    actions: [AutomationAction(action: "notify")]
                )
            ]
        )
        try store.save(configuration)
        let loaded = try store.load()
        #expect(loaded == configuration)
    }

    @Test("operator predicates support contains and negation")
    func operatorPredicates() {
        let rule = AutomationRule(
            id: "agent",
            when: AutomationWhen(category: "agent"),
            predicates: [
                "agent": .object(["contains": .string("codex")]),
                "surface.kind": .object(["not": .string("browser")])
            ],
            actions: [AutomationAction(action: "run", parameters: ["command": .string("true")])]
        )
        #expect(
            rule.matches(
                event: [
                    "name": "agent.hook.Stop",
                    "category": "agent",
                    "payload": [
                        "agent": "codex",
                        "kind": "terminal"
                    ]
                ]
            )
        )
    }

    @Test("automation RPCs preserve focus unless explicitly allowed")
    func focusPolicyIsOptIn() {
        let suppressed = CmuxAutomationInvocationContext.$focusAllowed.withValue(false) {
            TerminalController.socketCommandAllowsInAppFocusMutations(
                commandKey: "workspace.select",
                isV2: true
            )
        }
        let allowed = CmuxAutomationInvocationContext.$focusAllowed.withValue(true) {
            TerminalController.socketCommandAllowsInAppFocusMutations(
                commandKey: "workspace.select",
                isV2: true
            )
        }
        #expect(suppressed == false)
        #expect(allowed == true)
    }

    @Test("action-generated events carry their rule chain")
    func generatedEventCarriesOrigin() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        let origin = CmuxAutomationEventOrigin(ruleID: "a", chain: ["a", "b"])
        CmuxAutomationInvocationContext.$eventOrigin.withValue(origin) {
            bus.publish(name: "workspace.reordered", category: "workspace", source: "test")
        }
        let event = try #require(bus.retainedSnapshot().last)
        let encodedOrigin = try #require(event["automation_origin"] as? [String: Any])
        #expect(encodedOrigin["rule_id"] as? String == "a")
        #expect(encodedOrigin["chain"] as? [String] == ["a", "b"])
    }

    @Test("automation origin metadata survives a CLI-style RPC envelope")
    func parsesRPCOriginMetadata() {
        let origin = TerminalController.automationOrigin(
            from: #"{"id":"1","method":"workspace.reorder","automation_origin":{"rule_id":"a","chain":["a","b"]}}"#
        )
        #expect(origin?.ruleID == "a")
        #expect(origin?.chain == ["a", "b"])
    }
}
