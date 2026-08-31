import Darwin
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

    @Test("selector matching is deterministic and case-consistent")
    func selectorMatchingIsDeterministic() {
        let selectors = [
            "Agent.NEEDS_INPUT",
            "AGENT.*",
            "*.NEEDS_INPUT",
            "*NEEDS*"
        ]
        for selector in selectors {
            let rule = AutomationRule(
                id: selector,
                when: AutomationWhen(event: selector),
                actions: [AutomationAction(action: "notify")]
            )
            #expect(
                rule.matches(event: [
                    "name": "agent.needs_input",
                    "category": "agent"
                ])
            )
        }

        let containsRule = AutomationRule(
            id: "contains",
            when: AutomationWhen(category: "agent"),
            predicates: [
                "agent": .object(["contains": .string("CoDeX")])
            ],
            actions: [AutomationAction(action: "notify")]
        )
        #expect(
            containsRule.matches(event: [
                "name": "agent.status",
                "category": "agent",
                "payload": ["agent": "codex"]
            ])
        )
    }

    @Test("saving a symlinked configuration updates its target")
    func symlinkedConfigurationPreservesLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-symlink-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetURL = directory.appendingPathComponent("managed/automations.json")
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let linkURL = directory.appendingPathComponent("automations.json")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: targetURL.path
        )

        let store = AutomationConfigStore(fileURL: linkURL)
        let configuration = AutomationConfiguration(
            rules: [
                AutomationRule(
                    id: "managed",
                    when: AutomationWhen(event: "agent.ready"),
                    actions: [AutomationAction(action: "notify")]
                )
            ]
        )
        try store.save(configuration)
        _ = try store.updateRule(id: "managed") { $0.enabled = false }

        #expect(FileManager.default.fileExists(atPath: linkURL.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) == targetURL.path)
        #expect(try AutomationConfigStore(fileURL: targetURL).load().rules.first?.enabled == false)
    }

    @Test("run actions terminate background descendants")
    func processSessionCleansUpDescendants() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-process-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidURL = directory.appendingPathComponent("child.pid")
        let command = "sleep 5 & printf '%s' $! > '\(pidURL.path)'; exit 0"
        let session = AutomationProcessSession(command: command, environment: [:])

        _ = await session.run()
        let clock = ContinuousClock()
        var childPID: pid_t?
        for _ in 0..<50 {
            if let raw = try? String(contentsOf: pidURL, encoding: .utf8),
               let parsed = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = parsed
                break
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        let pid = try #require(childPID)
        for _ in 0..<50 {
            if kill(pid, 0) != 0, errno == ESRCH { break }
            try await clock.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) != 0)
    }
}
