import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentHookDeliveryQueueTests {
    @Test("Queue admission returns while downstream delivery is blocked")
    func enqueueDoesNotWaitForDelivery() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["first"])
        let queue = AgentHookDeliveryQueue { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(payload: "first", surfaceID: "surface-a")))
        try await probe.waitUntilStarted(count: 1)
        #expect(await probe.completedPayloads().isEmpty)
        #expect(queue.enqueue(try makeEvent(payload: "second", surfaceID: "surface-a")))

        await probe.release(payload: "first")
        try await probe.waitUntilCompleted(count: 2)
        #expect(await probe.completedPayloads() == ["first", "second"])
    }

    @Test("Admission rejects overflow while delivery is blocked and recovers after capacity returns")
    func admissionIsBoundedAcrossIngressAndResidentEvents() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["first"])
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 1,
            maximumResidentEvents: 1,
            maximumIngressEvents: 2
        ) { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(payload: "first", surfaceID: "surface-a")))
        try await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(payload: "second", surfaceID: "surface-b")))
        #expect(!queue.enqueue(try makeEvent(payload: "overflow", surfaceID: "surface-c")))

        await probe.release(payload: "first")
        try await probe.waitUntilCompleted(count: 2)
        #expect(queue.enqueue(try makeEvent(payload: "after-capacity", surfaceID: "surface-c")))
        try await probe.waitUntilCompleted(count: 3)
        #expect(await probe.completedPayloads().contains("after-capacity"))
    }

    @Test("Terminal lifecycle admission replaces stale buffered state when saturated")
    func terminalLifecycleReplacesStaleBufferedState() async throws {
        let activePayload = #"{"session_id":"session-a","state":"active"}"#
        let stalePayload = #"{"session_id":"session-a","state":"stale-running"}"#
        let latestPayload = #"{"session_id":"session-a","state":"latest-ended"}"#
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: [activePayload])
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 1,
            maximumResidentEvents: 1,
            maximumIngressEvents: 2
        ) { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: activePayload,
            surfaceID: "surface-a"
        )))
        try await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: stalePayload,
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: latestPayload,
            surfaceID: "surface-a"
        )))

        await probe.release(payload: activePayload)
        try await probe.waitUntilCompleted(count: 2)
        #expect(await probe.completedPayloads() == [activePayload, latestPayload])
    }

    @Test("Terminal lifecycle admission replaces stale actor-resident state")
    func terminalLifecycleReplacesActorResidentState() async throws {
        let activePayload = #"{"session_id":"session-a","state":"active"}"#
        let stalePrompt = #"{"session_id":"session-a","state":"stale-prompt"}"#
        let staleStop = #"{"session_id":"session-a","state":"stale-stop"}"#
        let latestPayload = #"{"session_id":"session-a","state":"latest-ended"}"#
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: [activePayload])
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 1,
            maximumResidentEvents: 4,
            maximumIngressEvents: 4
        ) { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: activePayload,
            surfaceID: "surface-a"
        )))
        try await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: stalePrompt,
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "stop",
            payload: staleStop,
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: latestPayload,
            surfaceID: "surface-a"
        )))

        await probe.release(payload: activePayload)
        try await probe.waitUntilCompleted(count: 2)
        #expect(await probe.completedPayloads() == [activePayload, latestPayload])
    }

    @Test("Terminal lifecycle has reserved execution capacity")
    func terminalLifecycleHasReservedExecutionCapacity() async throws {
        let ordinaryPayloads = (1...4).map { "ordinary-\($0)" }
        let terminalPayload = "terminal"
        let probe = AgentHookDeliveryTestProbe(
            blockedPayloads: Set(ordinaryPayloads)
        )
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 4,
            maximumResidentEvents: 5,
            maximumIngressEvents: 6
        ) { event in
            await probe.deliver(event)
        }

        for (index, payload) in ordinaryPayloads.enumerated() {
            #expect(queue.enqueue(try makeEvent(
                subcommand: "prompt-submit",
                payload: payload,
                surfaceID: "surface-\(index)"
            )))
        }
        try await probe.waitUntilStarted(count: 3)
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: terminalPayload,
            surfaceID: "surface-terminal"
        )))

        try await probe.waitUntilCompleted(count: 1)
        #expect(await probe.completedPayloads() == [terminalPayload])
        #expect(await probe.startedPayloads().contains(terminalPayload))

        for payload in ordinaryPayloads {
            await probe.release(payload: payload)
        }
        try await probe.waitUntilCompleted(count: ordinaryPayloads.count + 1)
    }

    @Test("Terminal lifecycle saturation preserves side effects and finalization")
    func terminalLifecycleDoesNotReplaceProtectedWork() async throws {
        let activePayload = #"{"session_id":"session-a","state":"active"}"#
        let notificationPayload = #"{"session_id":"session-a","message":"notify"}"#
        let needsInputPayload = #"{"session_id":"session-a","tool_name":"AskUserQuestion"}"#
        let finalizePayload = #"{"session_id":"session-a","state":"finalize"}"#
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: [activePayload])
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 1,
            maximumResidentEvents: 1,
            maximumIngressEvents: 4
        ) { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: activePayload,
            surfaceID: "surface-a"
        )))
        try await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(
            subcommand: "notification",
            payload: notificationPayload,
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "pre-tool-use",
            payload: needsInputPayload,
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-finalize",
            payload: finalizePayload,
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: #"{"session_id":"session-a","state":"ended"}"#,
            surfaceID: "surface-a"
        )))

        await probe.release(payload: activePayload)
        try await probe.waitUntilCompleted(count: 5)
        #expect(await probe.completedPayloads() == [
            activePayload,
            notificationPayload,
            needsInputPayload,
            finalizePayload,
            #"{"session_id":"session-a","state":"ended"}"#,
        ])
    }

    @Test("Terminal lifecycle saturation never evicts another lane's admitted terminal state")
    func terminalLifecycleDoesNotEvictAnotherLane() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["active"])
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 1,
            maximumResidentEvents: 1,
            maximumIngressEvents: 3
        ) { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: "active",
            surfaceID: "surface-active"
        )))
        try await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(
            subcommand: "stop",
            payload: "stop-a",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: "session-end-b",
            surfaceID: "surface-b"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: "session-end-c",
            surfaceID: "surface-c"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: "session-end-d",
            surfaceID: "surface-d"
        )))
        #expect(!queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: "session-end-overflow",
            surfaceID: "surface-overflow"
        )))

        await probe.release(payload: "active")
        try await probe.waitUntilCompleted(count: 5)
        #expect(await probe.completedPayloads() == [
            "active", "stop-a", "session-end-b", "session-end-c",
            "session-end-d",
        ])
    }

    @Test("Best-effort telemetry cannot monopolize resident delivery capacity")
    func bestEffortTelemetryReservesResidentLifecycleCapacity() async throws {
        let blockedTools = Set((1...3).map { "tool-\($0)" })
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: blockedTools)
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 4,
            maximumResidentEvents: 4,
            maximumIngressEvents: 4
        ) { event in
            await probe.deliver(event)
        }

        for index in 1...3 {
            #expect(queue.enqueue(try makeEvent(
                agent: "cursor",
                subcommand: "shell-exec",
                payload: "tool-\(index)",
                surfaceID: "surface-\(index)"
            )))
        }
        try await probe.waitUntilStarted(count: 3)

        #expect(!queue.enqueue(try makeEvent(
            agent: "cursor",
            subcommand: "shell-exec",
            payload: "tool-4",
            surfaceID: "surface-4"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: "lifecycle",
            surfaceID: "surface-4"
        )))
        try await probe.waitUntilStarted(count: 4)
        #expect(await probe.startedPayloads().contains("lifecycle"))

        for payload in blockedTools {
            await probe.release(payload: payload)
        }
        try await probe.waitUntilCompleted(count: 4)

        #expect(queue.enqueue(try makeEvent(
            agent: "cursor",
            subcommand: "shell-exec",
            payload: "tool-after-capacity",
            surfaceID: "surface-4"
        )))
        try await probe.waitUntilCompleted(count: 5)
    }

    @Test("Best-effort tool saturation cannot evict terminal lifecycle events")
    func toolIngressReservesTerminalLifecycleCapacityAndPreservesOrder() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["session-start"])
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 1,
            maximumResidentEvents: 1,
            maximumIngressEvents: 4
        ) { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-start",
            payload: "session-start",
            surfaceID: "surface-a"
        )))
        try await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(
            agent: "cursor",
            subcommand: "shell-exec",
            payload: "shell-exec",
            surfaceID: "surface-a"
        )))
        #expect(!queue.enqueue(try makeEvent(
            agent: "cursor",
            subcommand: "shell-done",
            payload: "shell-done-overflow",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "push-notification",
            payload: "push",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "stop",
            payload: "stop",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-end",
            payload: "session-end",
            surfaceID: "surface-a"
        )))
        #expect(!queue.enqueue(try makeEvent(
            subcommand: "pre-tool-use",
            payload: #"{"tool_name":"Read"}"#,
            surfaceID: "surface-a"
        )))

        await probe.release(payload: "session-start")
        try await probe.waitUntilCompleted(count: 5)
        #expect(await probe.completedPayloads() == [
            "session-start", "shell-exec", "push", "stop", "session-end",
        ])
    }

    @Test("Events in one delivery lane remain FIFO")
    func sameLaneDeliveryIsFIFO() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["first"])
        let queue = AgentHookDeliveryQueue { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(payload: "first", surfaceID: "surface-a")))
        #expect(queue.enqueue(try makeEvent(payload: "second", surfaceID: "surface-a")))
        try await probe.waitUntilStarted(count: 1)
        #expect(await probe.startedPayloads() == ["first"])

        await probe.release(payload: "first")
        try await probe.waitUntilCompleted(count: 2)
        #expect(await probe.startedPayloads() == ["first", "second"])
        #expect(await probe.completedPayloads() == ["first", "second"])
    }

    @Test("A decision barrier waits for its lane while an independent lane progresses")
    func decisionBarrierPreservesLaneOrderWithoutGlobalStall() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["lifecycle-a"])
        let barrierProbe = AgentHookDeliveryBarrierProbe()
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 2,
            maximumResidentEvents: 4,
            maximumIngressEvents: 4
        ) { event in
            await probe.deliver(event)
        }

        let lifecycleA = try makeEvent(payload: "lifecycle-a", surfaceID: "surface-a")
        #expect(queue.enqueue(lifecycleA))
        try await probe.waitUntilStarted(count: 1)

        let barrierTask = Task.detached {
            await barrierProbe.markStarted()
            let result = queue.waitForPriorDeliveries(
                orderingKey: lifecycleA.orderingKey,
                timeout: 3
            )
            await barrierProbe.complete(result: result)
            return result
        }
        try await barrierProbe.waitUntilStarted()
        #expect(queue.enqueue(try makeEvent(payload: "lifecycle-b", surfaceID: "surface-b")))

        try await probe.waitUntilStarted(count: 2)
        #expect(await probe.startedPayloads() == ["lifecycle-a", "lifecycle-b"])
        #expect(await probe.completedPayloads() == ["lifecycle-b"])
        #expect(await barrierProbe.result() == nil)

        await probe.release(payload: "lifecycle-a")
        #expect(await barrierTask.value)
        try await probe.waitUntilCompleted(count: 2)
        #expect(await probe.completedPayloads() == ["lifecycle-b", "lifecycle-a"])
    }

    @Test("A decision barrier covers the complete same-lane delivery backlog")
    func decisionBarrierCoversCompleteSameLaneBacklog() async throws {
        let fixture = try AgentHookStalledProcessFixture()
        defer { fixture.remove() }
        let process = AgentHookDeliveryProcess(
            executableURLProvider: { fixture.executableURL },
            processTimeout: .seconds(5),
            deliveryTimeout: .milliseconds(300),
            terminationGrace: .milliseconds(20)
        )
        let queue = AgentHookDeliveryQueue(process: process)
        let first = try makeEvent(payload: "first", surfaceID: "surface-backlog")
        let second = try makeEvent(payload: "second", surfaceID: "surface-backlog")

        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))

        let completedBeforeDecisionDeadline = await Task.detached {
            queue.waitForPriorDeliveries(
                orderingKey: first.orderingKey,
                timeout: 0.45
            )
        }.value
        #expect(
            completedBeforeDecisionDeadline,
            "Every event admitted before the decision must share one bounded lane-drain budget"
        )

        let eventuallyDrained = await Task.detached {
            queue.waitForPriorDeliveries(
                orderingKey: first.orderingKey,
                timeout: 1
            )
        }.value
        #expect(eventuallyDrained)
    }

    @Test("Global delivery concurrency is capped and queued lanes progress when a slot frees")
    func globalConcurrencyLimitQueuesDistinctLanes() async throws {
        let payloads = (1...6).map { "event-\($0)" }
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: Set(payloads))
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 4,
            maximumResidentEvents: 6,
            maximumIngressEvents: 7
        ) { event in
            await probe.deliver(event)
        }

        for (index, payload) in payloads.enumerated() {
            #expect(queue.enqueue(try makeEvent(payload: payload, surfaceID: "surface-\(index)")))
        }
        try await probe.waitUntilStarted(count: 4)
        #expect(await probe.startedPayloads().count == 4)
        #expect(await probe.maximumConcurrentDeliveryCount() == 4)

        let firstStarted = try #require(await probe.startedPayloads().first)
        await probe.release(payload: firstStarted)
        try await probe.waitUntilStarted(count: 5)
        #expect(await probe.maximumConcurrentDeliveryCount() == 4)

        for payload in payloads {
            await probe.release(payload: payload)
        }
        try await probe.waitUntilCompleted(count: payloads.count)
        #expect(await probe.maximumConcurrentDeliveryCount() == 4)
    }

    @Test("Delivery routing rejects decision hooks and preserves lane identity")
    func eventValidationAndRoutingContract() throws {
        let claudeFeed = try makeEvent(
            agent: "claude",
            subcommand: "feed",
            payload: "feed",
            surfaceID: "surface-a"
        )
        let codexStop = try makeEvent(
            agent: "codex",
            subcommand: "stop",
            payload: "stop",
            surfaceID: "surface-a"
        )
        let codexPreToolUse = try makeEvent(
            agent: "codex",
            subcommand: "pre-tool-use",
            payload: #"{"hook_event_name":"PreToolUse"}"#,
            surfaceID: "surface-a"
        )
        let codexPostToolUse = try makeEvent(
            agent: "codex",
            subcommand: "post-tool-use",
            payload: #"{"hook_event_name":"PostToolUse"}"#,
            surfaceID: "surface-a"
        )
        #expect(claudeFeed.deliveryArguments == ["hooks", "feed", "--source", "claude"])
        #expect(codexStop.deliveryArguments == ["hooks", "codex", "stop"])
        #expect(codexPreToolUse.deliveryArguments == [
            "hooks", "feed", "--source", "codex", "--event", "PreToolUse",
        ])
        #expect(codexPostToolUse.deliveryArguments == [
            "hooks", "feed", "--source", "codex", "--event", "PostToolUse",
        ])
        #expect(codexPreToolUse.isBestEffortTelemetry)
        #expect(codexPostToolUse.isBestEffortTelemetry)
        #expect(claudeFeed.orderingKey == codexStop.orderingKey)

        let unsupportedDecision = AgentHookDeliveryEvent(params: [
            "agent": "claude",
            "subcommand": "permission-request",
            "payload": "{}",
            "socket_path": "/tmp/cmux-test.sock",
            "environment": ["CMUX_SURFACE_ID": "surface-a"],
        ])
        let unsupportedEnvironment = AgentHookDeliveryEvent(params: [
            "agent": "claude",
            "subcommand": "prompt-submit",
            "payload": "{}",
            "socket_path": "/tmp/cmux-test.sock",
            "environment": ["CMUX_SOCKET_PASSWORD": "secret"],
        ])
        #expect(unsupportedDecision == nil)
        #expect(unsupportedEnvironment == nil)
    }

    @Test("Every agent shares generic lifecycle queue admission")
    func allAgentsShareLifecycleAdmission() throws {
        let agents = [
            "claude", "codex", "grok", "opencode", "pi", "omp", "campfire",
            "amp", "cursor", "gemini", "kiro", "antigravity", "rovodev",
            "hermes-agent", "copilot", "codebuddy", "factory", "qoder", "kimi",
            "future-agent",
        ]
        let subcommands = [
            "session-start", "prompt-submit", "stop", "notification",
            "agent-response", "approval-response", "shell-exec", "shell-done",
            "session-end", "session-finalize",
        ]
        for agent in agents {
            for subcommand in subcommands {
                let pidKey = agentPIDEnvironmentVariable(agent)
                let event = try #require(AgentHookDeliveryEvent(params: [
                    "agent": agent,
                    "subcommand": subcommand,
                    "payload": "{}",
                    "socket_path": "/tmp/cmux-test.sock",
                    "environment": [pidKey: "8535"],
                ]))
                #expect(event.orderingKey.contains("\0process\0\(agent)\0\(8535)"))
            }
        }
    }

    @Test("Queued delivery preserves replay-safe environment and relay provenance")
    func eventTransportAndEnvironmentBoundary() throws {
        let params: [String: Any] = [
            "agent": "claude",
            "subcommand": "prompt-submit",
            "payload": "{}",
            "relay_backed": true,
            "environment": [
                "ANTHROPIC_BASE_URL": "https://relay.example.test",
                "CMUX_AGENT_MANAGED_SUBAGENT": "1",
                "CMUX_CLAUDE_PID": "8535",
                "CMUX_SURFACE_ID": "surface-a",
            ],
        ]
        let event = try #require(AgentHookDeliveryEvent(
            params: params,
            deliverySocketPath: "/tmp/cmux-local.sock"
        ))
        #expect(event.socketPath == "/tmp/cmux-local.sock")
        #expect(event.relayBacked)
        #expect(event.environment["ANTHROPIC_BASE_URL"] == "https://relay.example.test")
        #expect(event.environment["CMUX_AGENT_MANAGED_SUBAGENT"] == "1")

        let process = AgentHookDeliveryProcess(executableURLProvider: { nil })
        let environment = process.deliveryEnvironment(
            event: event,
            executableURL: URL(fileURLWithPath: "/bin/true")
        )
        #expect(environment["CMUX_SOCKET_PATH"] == "/tmp/cmux-local.sock")
        #expect(environment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] == "1")
        #expect(environment["CMUX_AGENT_MANAGED_SUBAGENT"] == "1")
        #expect(environment["CMUX_SURFACE_ID"] == "surface-a")
        #expect(environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(environment["CMUX_CLAUDE_PID"] == nil)
        let relayStateDirectory = try #require(
            environment["CMUX_AGENT_HOOK_STATE_DIR"]
        )
        let localHome = try #require(environment["HOME"])
        let relayStateRoot = URL(fileURLWithPath: localHome, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("relay-hook-state", isDirectory: true)
            .standardizedFileURL.path
        #expect(
            URL(fileURLWithPath: relayStateDirectory)
                .standardizedFileURL.path
                .hasPrefix(relayStateRoot + "/"),
            "Relay replay must not share the host-local persistent hook store"
        )

        var secondRelayParams = params
        secondRelayParams["environment"] = [
            "CMUX_SURFACE_ID": "surface-b",
        ]
        let secondRelayEvent = try #require(AgentHookDeliveryEvent(
            params: secondRelayParams,
            deliverySocketPath: "/tmp/cmux-local.sock"
        ))
        let secondRelayEnvironment = process.deliveryEnvironment(
            event: secondRelayEvent,
            executableURL: URL(fileURLWithPath: "/bin/true")
        )
        #expect(
            secondRelayEnvironment["CMUX_AGENT_HOOK_STATE_DIR"] != relayStateDirectory,
            "Separate rewritten relay routes must not share persistent hook state"
        )

        var unsafeParams = params
        unsafeParams["environment"] = ["ANTHROPIC_API_KEY": "secret"]
        #expect(AgentHookDeliveryEvent(params: unsafeParams) == nil)
        unsafeParams["environment"] = ["CMUX_AGENT_HOOK_RELAY_ORIGIN": "1"]
        #expect(AgentHookDeliveryEvent(params: unsafeParams) == nil)

        var directParams = params
        directParams["relay_backed"] = false
        directParams["socket_path"] = "/tmp/cmux-direct.sock"
        let directEvent = try #require(AgentHookDeliveryEvent(params: directParams))
        let directEnvironment = process.deliveryEnvironment(
            event: directEvent,
            executableURL: URL(fileURLWithPath: "/bin/true")
        )
        #expect(directEnvironment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] == nil)
    }

    @Test("Oversized optional launch metadata does not discard lifecycle routing")
    func oversizedOptionalLaunchMetadataIsOmitted() throws {
        let event = try #require(AgentHookDeliveryEvent(params: [
            "agent": "claude",
            "subcommand": "prompt-submit",
            "payload": #"{"session_id":"large-launch"}"#,
            "socket_path": "/tmp/cmux-test.sock",
            "environment": [
                "CMUX_SURFACE_ID": "surface-large-launch",
                "CMUX_WORKSPACE_ID": "workspace-large-launch",
                "CMUX_CLAUDE_PID": "8535",
                "CMUX_AGENT_LAUNCH_ARGV_B64": String(repeating: "a", count: 80 * 1_024),
            ],
        ]))

        #expect(event.environment["CMUX_SURFACE_ID"] == "surface-large-launch")
        #expect(event.environment["CMUX_WORKSPACE_ID"] == "workspace-large-launch")
        #expect(event.environment["CMUX_CLAUDE_PID"] == "8535")
        #expect(event.environment["CMUX_AGENT_LAUNCH_ARGV_B64"] == nil)
    }

    @Test("Lifecycle delivery retries one downstream process failure")
    func lifecycleDeliveryRetriesOneProcessFailure() async throws {
        let fixture = try AgentHookDeliveryProcessFixture()
        defer { fixture.remove() }
        let process = AgentHookDeliveryProcess(
            executableURLProvider: { fixture.executableURL },
            processTimeout: .seconds(2),
            terminationGrace: .milliseconds(100)
        )
        let event = try makeEvent(
            subcommand: "session-end",
            payload: #"{"session_id":"retry-lifecycle"}"#,
            surfaceID: "surface-retry"
        )

        await process.deliver(event)

        #expect(try fixture.attemptCount() == 2)
    }

    @Test("Best-effort tool delivery is not retried after downstream failure")
    func bestEffortDeliveryDoesNotRetryProcessFailure() async throws {
        let fixture = try AgentHookDeliveryProcessFixture()
        defer { fixture.remove() }
        let process = AgentHookDeliveryProcess(
            executableURLProvider: { fixture.executableURL },
            processTimeout: .seconds(2),
            terminationGrace: .milliseconds(100)
        )
        let event = try makeEvent(
            agent: "codex",
            subcommand: "post-tool-use",
            payload: #"{"hook_event_name":"PostToolUse"}"#,
            surfaceID: "surface-best-effort"
        )

        await process.deliver(event)

        #expect(try fixture.attemptCount() == 1)
    }

    @MainActor
    @Test("Relay TTY resolution is scoped to the owning remote workspace")
    func relayTTYResolutionUsesOwningWorkspace() throws {
        let manager = TabManager()
        let firstWorkspace = manager.addWorkspace(select: true)
        let firstSurfaceID = try #require(firstWorkspace.focusedPanelId)
        let secondWorkspace = manager.addWorkspace(select: false)
        let secondSurfaceID = try #require(secondWorkspace.focusedPanelId)
        firstWorkspace.surfaceTTYNames[firstSurfaceID] = "/dev/ttys8535"
        secondWorkspace.surfaceTTYNames[secondSurfaceID] = "/dev/ttys8535"

        let controller = TerminalController.shared
        let previousManager = controller.activeTabManagerForCallerNotification()
        controller.setActiveTabManager(manager)
        defer { controller.setActiveTabManager(previousManager) }

        let resolved = controller.agentHookParametersResolvingRelayTTY([
            "relay_backed": true,
            "caller_tty": "/dev/ttys8535",
            "_cmux_remote_workspace_id": secondWorkspace.id.uuidString,
            "environment": [String: String](),
        ])
        let environment = try #require(resolved["environment"] as? [String: String])

        #expect(environment["CMUX_WORKSPACE_ID"] == secondWorkspace.id.uuidString)
        #expect(environment["CMUX_SURFACE_ID"] == secondSurfaceID.uuidString)
    }

    private func makeEvent(
        agent: String = "claude",
        subcommand: String = "prompt-submit",
        payload: String,
        surfaceID: String
    ) throws -> AgentHookDeliveryEvent {
        try #require(AgentHookDeliveryEvent(params: [
            "agent": agent,
            "subcommand": subcommand,
            "payload": payload,
            "socket_path": "/tmp/cmux-test.sock",
            "environment": [
                "CMUX_SURFACE_ID": surfaceID,
                agentPIDEnvironmentVariable(agent): "8535",
            ],
        ]))
    }

    private func agentPIDEnvironmentVariable(_ agent: String) -> String {
        let component = agent.uppercased().replacingOccurrences(
            of: "[^A-Z0-9]",
            with: "_",
            options: .regularExpression
        )
        return "CMUX_\(component)_PID"
    }
}

private struct AgentHookDeliveryProcessFixture {
    let directoryURL: URL
    let executableURL: URL
    let countURL: URL

    init() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let executableURL = directoryURL.appendingPathComponent("fail-once", isDirectory: false)
        let countURL = directoryURL.appendingPathComponent("fail-once.count", isDirectory: false)
        let script = """
        #!/bin/sh
        count_file="$0.count"
        count=0
        if [ -f "$count_file" ]; then
          count="$(cat "$count_file")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        if [ "$count" -eq 1 ]; then
          exit 42
        fi
        exit 0
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        self.directoryURL = directoryURL
        self.executableURL = executableURL
        self.countURL = countURL
    }

    func attemptCount() throws -> Int {
        let raw = try String(contentsOf: countURL, encoding: .utf8)
        return try #require(Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct AgentHookStalledProcessFixture {
    let directoryURL: URL
    let executableURL: URL

    init() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-agent-hook-stalled-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let executableURL = directoryURL.appendingPathComponent(
            "stall",
            isDirectory: false
        )
        try """
        #!/bin/sh
        exec /bin/sleep 5
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        self.directoryURL = directoryURL
        self.executableURL = executableURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private actor AgentHookDeliveryBarrierProbe {
    private let startedEvents: AsyncStream<Void>
    private let startedEventContinuation: AsyncStream<Void>.Continuation
    private var started = false
    private var completedResult: Bool?

    init() {
        let startedPair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        startedEvents = startedPair.stream
        startedEventContinuation = startedPair.continuation
    }

    func markStarted() {
        started = true
        startedEventContinuation.yield(())
    }

    func complete(result: Bool) {
        completedResult = result
    }

    func result() -> Bool? {
        completedResult
    }

    func waitUntilStarted() async throws {
        guard !started else { return }
        let events = startedEvents
        let outcome = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events {
                    return true
                }
                return false
            }
            group.addTask {
                do {
                    // A genuine assertion deadline, not a polling or settling sleep.
                    try await ContinuousClock().sleep(for: .seconds(3))
                    return false
                } catch {
                    return true
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard outcome else {
            throw AgentHookDeliveryProbeError.timedOut(
                state: "barrier started",
                expected: 1,
                observed: 0
            )
        }
    }
}

private actor AgentHookDeliveryTestProbe {
    private enum WaitOutcome: Equatable, Sendable {
        case satisfied
        case timedOut
    }

    private let blockedPayloads: Set<String>
    private let startedEvents: AsyncStream<Int>
    private let startedEventContinuation: AsyncStream<Int>.Continuation
    private let completedEvents: AsyncStream<Int>
    private let completedEventContinuation: AsyncStream<Int>.Continuation
    private var releasedPayloads: Set<String> = []
    private var started: [String] = []
    private var completed: [String] = []
    private var activeDeliveryCount = 0
    private var maximumActiveDeliveryCount = 0
    private var blockedEventContinuations: [String: AsyncStream<Void>.Continuation] = [:]

    init(blockedPayloads: Set<String>) {
        self.blockedPayloads = blockedPayloads
        let startedPair = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        startedEvents = startedPair.stream
        startedEventContinuation = startedPair.continuation
        let completedPair = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        completedEvents = completedPair.stream
        completedEventContinuation = completedPair.continuation
    }

    func deliver(_ event: AgentHookDeliveryEvent) async {
        started.append(event.payload)
        startedEventContinuation.yield(started.count)
        activeDeliveryCount += 1
        maximumActiveDeliveryCount = max(maximumActiveDeliveryCount, activeDeliveryCount)
        if blockedPayloads.contains(event.payload), !releasedPayloads.contains(event.payload) {
            let blockedPair = AsyncStream.makeStream(
                of: Void.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            blockedEventContinuations[event.payload] = blockedPair.continuation
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in blockedPair.stream { return }
                }
                group.addTask {
                    do {
                        // A bounded test-fixture deadline prevents a queue regression
                        // from retaining the app-host test process indefinitely.
                        try await ContinuousClock().sleep(for: .seconds(5))
                    } catch {}
                }
                await group.next()
                group.cancelAll()
            }
            blockedEventContinuations.removeValue(forKey: event.payload)?.finish()
        }
        completed.append(event.payload)
        completedEventContinuation.yield(completed.count)
        activeDeliveryCount -= 1
    }

    func release(payload: String) {
        releasedPayloads.insert(payload)
        if let continuation = blockedEventContinuations.removeValue(forKey: payload) {
            continuation.yield(())
            continuation.finish()
        }
    }

    func waitUntilStarted(count: Int) async throws {
        try await waitUntil(
            "started",
            count: count,
            currentCount: started.count,
            events: startedEvents
        )
    }

    func waitUntilCompleted(count: Int) async throws {
        try await waitUntil(
            "completed",
            count: count,
            currentCount: completed.count,
            events: completedEvents
        )
    }

    func startedPayloads() -> [String] {
        started
    }

    func completedPayloads() -> [String] {
        completed
    }

    func maximumConcurrentDeliveryCount() -> Int {
        maximumActiveDeliveryCount
    }

    private func waitUntil(
        _ state: String,
        count: Int,
        currentCount: Int,
        events: AsyncStream<Int>
    ) async throws {
        guard currentCount < count else { return }
        let outcome = await withTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                for await observedCount in events where observedCount >= count {
                    return .satisfied
                }
                return .timedOut
            }
            group.addTask {
                do {
                    // A genuine assertion deadline, not a polling or settling sleep.
                    try await ContinuousClock().sleep(for: .seconds(3))
                    return .timedOut
                } catch {
                    return .satisfied
                }
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        guard outcome == .satisfied else {
            let observed = state == "started" ? started.count : completed.count
            throw AgentHookDeliveryProbeError.timedOut(
                state: state,
                expected: count,
                observed: observed
            )
        }
    }
}

private enum AgentHookDeliveryProbeError: Error {
    case timedOut(state: String, expected: Int, observed: Int)
}
