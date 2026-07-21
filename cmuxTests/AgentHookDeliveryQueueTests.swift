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
        await probe.waitUntilStarted(count: 1)
        #expect(await probe.completedPayloads().isEmpty)
        #expect(queue.enqueue(try makeEvent(payload: "second", surfaceID: "surface-a")))

        await probe.release(payload: "first")
        await probe.waitUntilCompleted(count: 2)
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
        await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(payload: "second", surfaceID: "surface-b")))
        #expect(!queue.enqueue(try makeEvent(payload: "overflow", surfaceID: "surface-c")))

        await probe.release(payload: "first")
        await probe.waitUntilCompleted(count: 2)
        #expect(queue.enqueue(try makeEvent(payload: "after-capacity", surfaceID: "surface-c")))
        await probe.waitUntilCompleted(count: 3)
        #expect(await probe.completedPayloads().contains("after-capacity"))
    }

    @Test("Tool saturation cannot evict a later lifecycle event")
    func toolIngressReservesLifecycleCapacityAndPreservesOrder() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["session-start"])
        let queue = AgentHookDeliveryQueue(
            maximumConcurrentDeliveries: 1,
            maximumResidentEvents: 1,
            maximumIngressEvents: 2
        ) { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(
            subcommand: "session-start",
            payload: "session-start",
            surfaceID: "surface-a"
        )))
        await probe.waitUntilStarted(count: 1)
        #expect(queue.enqueue(try makeEvent(
            subcommand: "pre-tool-use",
            payload: "tool",
            surfaceID: "surface-a"
        )))
        #expect(!queue.enqueue(try makeEvent(
            subcommand: "push-notification",
            payload: "claude-tool-overflow",
            surfaceID: "surface-a"
        )))
        #expect(!queue.enqueue(try makeEvent(
            agent: "codex",
            subcommand: "post-tool-use",
            payload: "codex-tool-overflow",
            surfaceID: "surface-a"
        )))
        #expect(queue.enqueue(try makeEvent(
            subcommand: "prompt-submit",
            payload: "prompt",
            surfaceID: "surface-a"
        )))

        await probe.release(payload: "session-start")
        await probe.waitUntilCompleted(count: 3)
        #expect(await probe.completedPayloads() == ["session-start", "tool", "prompt"])
    }

    @Test("Events in one delivery lane remain FIFO")
    func sameLaneDeliveryIsFIFO() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayloads: ["first"])
        let queue = AgentHookDeliveryQueue { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(payload: "first", surfaceID: "surface-a")))
        #expect(queue.enqueue(try makeEvent(payload: "second", surfaceID: "surface-a")))
        await probe.waitUntilStarted(count: 1)
        #expect(await probe.startedPayloads() == ["first"])

        await probe.release(payload: "first")
        await probe.waitUntilCompleted(count: 2)
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
        await probe.waitUntilStarted(count: 4)
        #expect(await probe.startedPayloads().count == 4)
        #expect(await probe.maximumConcurrentDeliveryCount() == 4)

        let firstStarted = try #require(await probe.startedPayloads().first)
        await probe.release(payload: firstStarted)
        await probe.waitUntilStarted(count: 5)
        #expect(await probe.maximumConcurrentDeliveryCount() == 4)

        for payload in payloads {
            await probe.release(payload: payload)
        }
        await probe.waitUntilCompleted(count: payloads.count)
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

    @Test("Queued delivery preserves replay-safe environment and relay provenance")
    func eventTransportAndEnvironmentBoundary() throws {
        let params: [String: Any] = [
            "agent": "claude",
            "subcommand": "prompt-submit",
            "payload": "{}",
            "socket_path": "127.0.0.1:64007",
            "relay_backed": true,
            "environment": [
                "ANTHROPIC_BASE_URL": "https://relay.example.test",
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

        let process = AgentHookDeliveryProcess(executableURLProvider: { nil })
        let environment = process.deliveryEnvironment(
            event: event,
            executableURL: URL(fileURLWithPath: "/bin/true")
        )
        #expect(environment["CMUX_SOCKET_PATH"] == "/tmp/cmux-local.sock")
        #expect(environment["CMUX_AGENT_HOOK_RELAY_ORIGIN"] == "1")

        var unsafeParams = params
        unsafeParams["environment"] = ["ANTHROPIC_API_KEY": "secret"]
        #expect(AgentHookDeliveryEvent(params: unsafeParams) == nil)
        unsafeParams["environment"] = ["CMUX_AGENT_HOOK_RELAY_ORIGIN": "1"]
        #expect(AgentHookDeliveryEvent(params: unsafeParams) == nil)

        var directParams = params
        directParams["relay_backed"] = false
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
                agent == "claude" ? "CMUX_CLAUDE_PID" : "CMUX_CODEX_PID": "8535",
            ],
        ]))
    }
}

private actor AgentHookDeliveryTestProbe {
    private let blockedPayloads: Set<String>
    private var releasedPayloads: Set<String> = []
    private var started: [String] = []
    private var completed: [String] = []
    private var activeDeliveryCount = 0
    private var maximumActiveDeliveryCount = 0
    private var blockedContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var startedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(blockedPayloads: Set<String>) {
        self.blockedPayloads = blockedPayloads
    }

    func deliver(_ event: AgentHookDeliveryEvent) async {
        started.append(event.payload)
        activeDeliveryCount += 1
        maximumActiveDeliveryCount = max(maximumActiveDeliveryCount, activeDeliveryCount)
        resumeStartedWaiters()
        if blockedPayloads.contains(event.payload), !releasedPayloads.contains(event.payload) {
            await withCheckedContinuation { continuation in
                blockedContinuations[event.payload] = continuation
            }
        }
        completed.append(event.payload)
        activeDeliveryCount -= 1
        resumeCompletedWaiters()
    }

    func release(payload: String) {
        releasedPayloads.insert(payload)
        blockedContinuations.removeValue(forKey: payload)?.resume()
    }

    func waitUntilStarted(count: Int) async {
        guard started.count < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count: count, continuation: continuation))
        }
    }

    func waitUntilCompleted(count: Int) async {
        guard completed.count < count else { return }
        await withCheckedContinuation { continuation in
            completedWaiters.append((count: count, continuation: continuation))
        }
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

    private func resumeStartedWaiters() {
        let satisfied = startedWaiters.filter { started.count >= $0.count }
        startedWaiters.removeAll { started.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func resumeCompletedWaiters() {
        let satisfied = completedWaiters.filter { completed.count >= $0.count }
        completedWaiters.removeAll { completed.count >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
