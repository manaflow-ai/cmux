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

    @Test("Best-effort tool saturation cannot evict user-visible events")
    func toolIngressReservesUserVisibleCapacityAndPreservesOrder() async throws {
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
            agent: "codex",
            subcommand: "post-tool-use",
            payload: "tool",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "push-notification",
            payload: "push",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "pre-tool-use",
            payload: "needs-input-tool",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: "prompt",
            surfaceID: "surface-a"
        )))
        #expect(!queue.enqueue(try makeEvent(
            agent: "codex",
            subcommand: "post-tool-use",
            payload: "codex-tool-overflow",
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
            "session-start", "tool", "push", "needs-input-tool", "prompt",
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
        #expect(claudeFeed.deliveryArguments == ["hooks", "feed", "--source", "claude"])
        #expect(codexStop.deliveryArguments == ["hooks", "codex", "stop"])
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
