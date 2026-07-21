import Foundation
import Testing

@Suite(.serialized)
struct AgentHookDeliveryQueueTests {
    @Test("Queue admission returns while downstream delivery is blocked")
    func enqueueDoesNotWaitForDelivery() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayload: "first")
        let queue = AgentHookDeliveryQueue { event in
            await probe.deliver(event)
        }
        let event = try makeEvent(payload: "first", surfaceID: "surface-a")

        #expect(queue.enqueue(event))
        let started = await probe.waitUntilStarted(count: 1)
        #expect(started)
        #expect(await probe.completedPayloads().isEmpty)

        await probe.releaseBlockedDelivery()
        await queue.waitUntilIdle()
        #expect(await probe.completedPayloads() == ["first"])
    }

    @Test("Events in one delivery lane remain FIFO")
    func sameLaneDeliveryIsFIFO() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayload: "first")
        let queue = AgentHookDeliveryQueue { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(payload: "first", surfaceID: "surface-a")))
        #expect(queue.enqueue(try makeEvent(payload: "second", surfaceID: "surface-a")))
        let firstStarted = await probe.waitUntilStarted(count: 1)
        #expect(firstStarted)

        await probe.releaseBlockedDelivery()
        await queue.waitUntilIdle()
        #expect(await probe.startedPayloads() == ["first", "second"])
        #expect(await probe.completedPayloads() == ["first", "second"])
    }

    @Test("Independent delivery lanes drain concurrently")
    func differentSurfaceProgressesWhileFirstLaneIsBlocked() async throws {
        let probe = AgentHookDeliveryTestProbe(blockedPayload: "first")
        let queue = AgentHookDeliveryQueue { event in
            await probe.deliver(event)
        }

        #expect(queue.enqueue(try makeEvent(payload: "first", surfaceID: "surface-a")))
        let firstStarted = await probe.waitUntilStarted(count: 1)
        #expect(firstStarted)
        #expect(queue.enqueue(try makeEvent(payload: "other", surfaceID: "surface-b")))
        let bothStarted = await probe.waitUntilStarted(count: 2)
        #expect(bothStarted)
        let otherCompleted = await probe.waitUntilCompleted(count: 1)
        #expect(otherCompleted)
        #expect(await probe.startedPayloads().contains("other"))
        #expect(await probe.completedPayloads() == ["other"])

        await probe.releaseBlockedDelivery()
        await queue.waitUntilIdle()
        #expect(Set(await probe.completedPayloads()) == Set(["first", "other"]))
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
    private let blockedPayload: String
    private var started: [String] = []
    private var completed: [String] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    init(blockedPayload: String) {
        self.blockedPayload = blockedPayload
    }

    func deliver(_ event: AgentHookDeliveryEvent) async {
        started.append(event.payload)
        if event.payload == blockedPayload, !releaseRequested {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        completed.append(event.payload)
    }

    func releaseBlockedDelivery() {
        releaseRequested = true
        blockedContinuation?.resume()
        blockedContinuation = nil
    }

    func startedPayloads() -> [String] {
        started
    }

    func completedPayloads() -> [String] {
        completed
    }

    func waitUntilStarted(count: Int) async -> Bool {
        await waitUntil { started.count >= count }
    }

    func waitUntilCompleted(count: Int) async -> Bool {
        await waitUntil { completed.count >= count }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if predicate() { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
