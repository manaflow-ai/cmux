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
                    actions: [AutomationAction(action: "notify", parameters: ["nullable": .null])]
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

    @Test("boolean predicates reject unknown string spellings")
    func unknownBooleanStringsDoNotCoerceToFalse() {
        let rule = AutomationRule(
            id: "state",
            when: AutomationWhen(category: "agent"),
            predicates: ["enabled": .bool(false)],
            actions: [AutomationAction(action: "notify")]
        )
        #expect(
            !rule.matches(event: [
                "name": "agent.status",
                "category": "agent",
                "payload": ["enabled": "pending"]
            ])
        )
    }

    @Test("surface kind matching ignores the event envelope type")
    func surfaceKindDoesNotUseEventEnvelopeType() {
        let rule = AutomationRule(
            id: "surface-kind",
            when: AutomationWhen(event: "surface.changed"),
            predicates: ["surface.kind": .object(["not": .string("browser")])],
            actions: [AutomationAction(action: "notify")]
        )
        #expect(!rule.matches(event: [
            "name": "surface.changed",
            "type": "event",
            "payload": [:]
        ]))
        #expect(rule.matches(event: [
            "name": "surface.changed",
            "type": "event",
            "payload": ["kind": "terminal"]
        ]))
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

    @Test("automation origin metadata is carried by the internal CLI envelope")
    func parsesInternalAutomationEnvelope() throws {
        let payload = #"{"rule_id":"a","chain":["a","b"]}"#
        let encoded = Data(payload.utf8).base64EncodedString()
        let envelope = TerminalController.automationCommandEnvelope(
            from: "__cmux_automation_origin \(encoded) workspace.reorder"
        )
        #expect(envelope?.command == "workspace.reorder")
        #expect(envelope?.origin.ruleID == "a")
        #expect(envelope?.origin.chain == ["a", "b"])
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
    func symlinkedConfigurationPreservesLink() async throws {
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
        _ = try await store.updateRuleOffMain(id: "managed") { $0.enabled = false }

        #expect(FileManager.default.fileExists(atPath: linkURL.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) == targetURL.path)
        #expect(try AutomationConfigStore(fileURL: targetURL).load().rules.first?.enabled == false)
    }

    @Test("scalar array matching keeps large integers exact")
    func scalarArrayMatchingKeepsLargeIntegersExact() {
        let first: Int64 = 9_007_199_254_740_993
        let adjacent: Int64 = 9_007_199_254_740_992
        let rule = AutomationRule(
            id: "large-number",
            when: AutomationWhen(event: "numbers"),
            predicates: ["values": .array([.integer(first)])],
            actions: [AutomationAction(action: "notify")]
        )
        #expect(!rule.matches(event: [
            "name": "numbers",
            "payload": ["values": [adjacent]]
        ]))
        #expect(rule.matches(event: [
            "name": "numbers",
            "payload": ["values": [first]]
        ]))
        #expect(rule.matches(event: [
            "name": "numbers",
            "payload": ["values": [Double(first)]]
        ]))
    }

    @Test("rule redaction covers predicates and session identifiers")
    func ruleRedactionCoversPredicatesAndSessions() throws {
        let rule = AutomationRule(
            id: "redact",
            when: AutomationWhen(event: "secret"),
            predicates: [
                "authorization": .string("bearer secret"),
                "nested": .object(["session_id": .string("session-secret")])
            ],
            actions: [AutomationAction(action: "notify", parameters: ["token": .string("token-secret")])]
        )
        let redacted = AutomationPayloadRedactor().rule(rule)
        #expect(redacted.predicates["authorization"] == .string("[redacted]"))
        #expect(redacted.predicates["nested"] == .object(["session_id": .string("[redacted]")]))
        #expect(redacted.actions[0].value(for: "token") == .string("[redacted]"))

        let webhook = AutomationRule(
            id: "webhook",
            when: AutomationWhen(event: "secret"),
            actions: [AutomationAction(
                action: "webhook",
                parameters: [
                    "url": .string("https://hooks.example/hook?token=query-secret&keep=visible")
                ]
            )]
        )
        let redactedWebhook = AutomationPayloadRedactor().rule(webhook)
        let redactedURL = try #require(redactedWebhook.actions[0].string(for: "url"))
        #expect(!redactedURL.contains("query-secret"))
        #expect(redactedURL.contains("keep=visible"))
    }

    @Test("redaction preserves URL arrays and signed query credentials")
    func redactionPreservesURLArraysAndSignedQueryCredentials() throws {
        let signedURL = "https://hooks.example/one?X-Amz-Signature=signed-secret&keep=visible"
        let authURL = "https://hooks.example/two?auth=auth-secret&keep=visible"
        let apiKeyURL = "https://hooks.example/three?key=api-secret&keep=visible"
        let rule = AutomationRule(
            id: "url-arrays",
            when: AutomationWhen(event: "secret"),
            predicates: [
                "urls": .array([.string(signedURL), .string(authURL), .string(apiKeyURL)])
            ],
            actions: [AutomationAction(
                action: "webhook",
                parameters: [
                    "urls": .array([.string(signedURL), .string(authURL), .string(apiKeyURL)])
                ]
            )]
        )
        let redactor = AutomationPayloadRedactor()
        let redactedRule = redactor.rule(rule)
        let predicateURLs = try #require(redactedRule.predicates["urls"]?.arrayValue)
        let actionURLs = try #require(redactedRule.actions[0].value(for: "urls")?.arrayValue)
        for values in [predicateURLs, actionURLs] {
            let strings = values.compactMap { $0.stringValue }
            #expect(strings.count == 3)
            #expect(strings.allSatisfy { !$0.contains("signed-secret") })
            #expect(strings.allSatisfy { !$0.contains("auth-secret") })
            #expect(strings.allSatisfy { !$0.contains("api-secret") })
            #expect(strings.allSatisfy { $0.contains("keep=visible") })
        }

        let redactedEvent = redactor.event([
            "payload": ["urls": [signedURL, authURL, apiKeyURL]]
        ])
        let eventPayload = try #require(redactedEvent["payload"] as? [String: Any])
        let eventURLs = try #require(eventPayload["urls"] as? [String])
        #expect(eventURLs.count == 3)
        #expect(eventURLs.allSatisfy { !$0.contains("signed-secret") })
        #expect(eventURLs.allSatisfy { !$0.contains("auth-secret") })
        #expect(eventURLs.allSatisfy { !$0.contains("api-secret") })
        #expect(eventURLs.allSatisfy { $0.contains("keep=visible") })
    }

    @Test("bounded JSON reads accumulate short chunks")
    func boundedJSONReadsAccumulateShortChunks() throws {
        let expected = Data("{\"name\":\"event\"}".utf8)
        let chunks = [
            Data("{\"name\":\"".utf8),
            Data("event\"}".utf8)
        ]
        var index = 0
        let data = try AutomationConfigStore.readBoundedData(maximumBytes: 64) { _ in
            guard index < chunks.count else { return Data() }
            defer { index += 1 }
            return chunks[index]
        }
        #expect(data == expected)
    }

    @Test("configuration validation rejects empty selectors and oversized action objects")
    func configurationValidationBoundsSelectorsAndActions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationConfigStore(fileURL: directory.appendingPathComponent("automations.json"))
        let emptySelector = AutomationConfiguration(rules: [
            AutomationRule(
                id: "empty-selector",
                when: AutomationWhen(event: "   "),
                actions: [AutomationAction(action: "notify")]
            )
        ])
        #expect(throws: AutomationConfigStoreError.self) { try store.save(emptySelector) }

        var parameters: [String: AutomationJSONValue] = [:]
        for index in 0...256 { parameters["key-\(index)"] = .string("value") }
        let oversizedAction = AutomationConfiguration(rules: [
            AutomationRule(
                id: "oversized-action",
                when: AutomationWhen(event: "action"),
                actions: [AutomationAction(action: "notify", parameters: parameters)]
            )
        ])
        #expect(throws: AutomationConfigStoreError.self) { try store.save(oversizedAction) }
    }

    @Test("configuration loading rejects deep JSON before decoding")
    func configurationLoadingRejectsDeepJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-depth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("automations.json")
        var nested = "\"value\""
        for _ in 0..<32 { nested = "[\(nested)]" }
        let json = "{\"version\":1,\"rules\":[{\"id\":\"deep\",\"when\":{\"event\":\"x\"},\"where\":{\"value\":\(nested)},\"then\":[{\"action\":\"notify\"}]}]}"
        try Data(json.utf8).write(to: fileURL)
        #expect(throws: AutomationConfigStoreError.self) {
            try AutomationConfigStore(fileURL: fileURL).load()
        }
    }

    @Test("configuration save rejects oversized encoded data")
    func configurationSaveRejectsOversizedData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-size-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("automations.json")
        let configuration = AutomationConfiguration(rules: [
            AutomationRule(
                id: "large",
                when: AutomationWhen(event: "large"),
                predicates: ["value": .string(String(repeating: "x", count: 4 * 1024 * 1024))],
                actions: [AutomationAction(action: "notify")]
            )
        ])
        #expect(throws: AutomationConfigStoreError.fileTooLarge) {
            try AutomationConfigStore(fileURL: fileURL).save(configuration)
        }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("webhook credentials require HTTPS and are stripped across origins")
    func webhookCredentialTransportPolicy() throws {
        let policy = AutomationWebhookPolicy()
        let httpURL = try #require(URL(string: "http://example.test/hook"))
        let httpsURL = try #require(URL(string: "https://example.test/hook"))
        let userInfoURL = try #require(URL(string: "https://user:password@example.test/hook"))
        #expect(!policy.isValid(url: httpURL, headers: ["Authorization": "Bearer secret"]))
        #expect(policy.isValid(url: httpURL, headers: ["X-Trace": "trace"]))
        #expect(policy.isValid(url: httpsURL, headers: ["Authorization": "Bearer secret"]))
        #expect(!policy.isValid(url: userInfoURL, headers: [:]))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-webhook-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationConfigStore(fileURL: directory.appendingPathComponent("automations.json"))
        let invalidConfiguration = AutomationConfiguration(rules: [
            AutomationRule(
                id: "insecure-webhook",
                when: AutomationWhen(event: "webhook"),
                actions: [AutomationAction(
                    action: "webhook",
                    parameters: [
                        "url": .string(httpURL.absoluteString),
                        "headers": .object(["Authorization": .string("Bearer secret")])
                    ]
                )]
            )
        ])
        #expect(throws: AutomationConfigStoreError.self) { try store.save(invalidConfiguration) }

        let delegate = AutomationWebhookRedirectDelegate(
            originalURL: httpsURL,
            sensitiveHeaderNames: policy.credentialHeaderNames(in: ["Authorization": "Bearer secret"])
        )
        var redirected = URLRequest(url: try #require(URL(string: "https://other.test/hook")))
        redirected.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        redirected.setValue("trace", forHTTPHeaderField: "X-Trace")
        let sanitized = try #require(delegate.requestForRedirect(redirected))
        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sanitized.value(forHTTPHeaderField: "X-Trace") == "trace")
        let insecure = URLRequest(url: httpURL)
        #expect(delegate.requestForRedirect(insecure) == nil)
        let credentialFreeDelegate = AutomationWebhookRedirectDelegate(
            originalURL: httpsURL,
            sensitiveHeaderNames: []
        )
        #expect(credentialFreeDelegate.requestForRedirect(insecure) == nil)
    }

    @Test("engine fires a real run action and records completion")
    @MainActor
    func engineFiresRealRunActionAndRecordsCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-engine-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("marker.txt")
        let markerPath = markerURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let store = AutomationConfigStore(
            fileURL: directory.appendingPathComponent("automations.json")
        )
        try store.save(AutomationConfiguration(rules: [
            AutomationRule(
                id: "run-marker",
                when: AutomationWhen(event: "workspace.created"),
                actions: [AutomationAction(
                    action: "run",
                    parameters: [
                        "command": .string(
                            "printf '%s' \"$CMUX_AUTOMATION_EVENT_NAME\" > '\(markerPath)'"
                        )
                    ]
                )]
            )
        ]))

        let bus = CmuxEventBus(retainedEventLimit: 32)
        let engine = AutomationEngine(configStore: store, eventBus: bus)
        defer { engine.stop() }
        engine.start()

        var loaded = false
        for _ in 0..<250 {
            if engine.rule(withID: "run-marker") != nil {
                loaded = true
                break
            }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        #expect(loaded)

        bus.publish(
            name: "workspace.created",
            category: "workspace",
            source: "automation-test"
        )

        var markerContents: String?
        for _ in 0..<250 {
            markerContents = try? String(contentsOf: markerURL, encoding: .utf8)
            if markerContents != nil { break }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        #expect(markerContents == "workspace.created")
        #expect(
            engine.logsPayload(limit: 32).contains {
                ($0["rule_id"] as? String) == "run-marker" &&
                    ($0["status"] as? String) == "completed"
            }
        )
    }

    @Test("engine stops a direct action cycle")
    @MainActor
    func engineStopsDirectActionCycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-engine-cycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspaceID = UUID()
        let store = AutomationConfigStore(
            fileURL: directory.appendingPathComponent("automations.json")
        )
        try store.save(AutomationConfiguration(rules: [
            AutomationRule(
                id: "cycle",
                when: AutomationWhen(event: "cycle.event"),
                actions: [AutomationAction(action: "notify")]
            )
        ]))

        let bus = CmuxEventBus(retainedEventLimit: 32)
        var notificationCount = 0
        let engine = AutomationEngine(
            configStore: store,
            eventBus: bus,
            notificationHandler: { _, _, _, _, _ in
                notificationCount += 1
                bus.publish(
                    name: "cycle.event",
                    category: "cycle",
                    source: "automation-test",
                    workspaceId: workspaceID.uuidString
                )
            }
        )
        defer { engine.stop() }
        engine.start()

        var loaded = false
        for _ in 0..<250 {
            if engine.rule(withID: "cycle") != nil {
                loaded = true
                break
            }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        #expect(loaded)

        bus.publish(
            name: "cycle.event",
            category: "cycle",
            source: "automation-test",
            workspaceId: workspaceID.uuidString
        )

        var cycleSkipped = false
        for _ in 0..<250 {
            cycleSkipped = engine.logsPayload(limit: 32).contains {
                ($0["rule_id"] as? String) == "cycle" &&
                    ($0["status"] as? String) == "skipped_loop"
            }
            if cycleSkipped { break }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        #expect(notificationCount == 1)
        #expect(cycleSkipped)
    }
}
