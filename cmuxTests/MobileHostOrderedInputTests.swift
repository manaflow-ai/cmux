import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct MobileHostOrderedInputTests {
    @Test
    func terminalInputRunsSeriallyWhileOtherRequestsRemainConcurrent() async throws {
        let transport = OrderedInputRecordingTransport()
        let gate = OrderedInputHandlerGate()
        let connection = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                await gate.handle(request)
                return .ok(["handled": request.id ?? NSNull()])
            },
            onClose: { _ in }
        )
        let batch = try Self.framedBatch([
            ("input-1", "terminal.input"),
            ("input-2", "terminal.input"),
            ("workspace", "mobile.workspace.list"),
        ])

        await connection.debugHandleReceiveDataForTesting(batch)
        await gate.waitUntilFirstInputStarts()
        await gate.waitUntilWorkspaceStarts()

        #expect(!(await gate.secondInputStarted()))
        await gate.releaseFirstInput()
        await gate.waitUntilSecondInputStarts()
        _ = await transport.waitForResponseCount(3)

        let inputResponseIDs = await transport.responseIDs().filter {
            $0.hasPrefix("input-")
        }
        // Application order is proven by the gate assertions above; response
        // writes are dispatched to concurrent tasks and may interleave.
        #expect(Set(inputResponseIDs) == Set(["input-1", "input-2"]))
        await connection.close(reason: "test complete")
    }

    @Test
    func queuedOrderedInputStillConsumesRPCWorkQuota() async throws {
        let transport = OrderedInputRecordingTransport()
        let gate = OrderedInputHandlerGate()
        let connection = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                await gate.handle(request)
                return .ok([:])
            },
            onClose: { _ in }
        )
        let initialRequests = (
            1...MobileHostRPCWorkQuota.recommendedMaximumConcurrentRequestCount
        ).map { ("input-\($0)", "terminal.input") }
        await connection.debugHandleReceiveDataForTesting(
            try Self.framedBatch(initialRequests)
        )
        await gate.waitUntilFirstInputStarts()
        await connection.debugHandleReceiveDataForTesting(
            try Self.framedBatch([("input-overflow", "terminal.input")])
        )

        #expect(await transport.closeCount() == 1)
        #expect(await gate.handledRequestCount() == 1)
        await gate.releaseFirstInput()
    }

    @Test
    func orderedInputOnAnotherSurfaceIsNotBlocked() async throws {
        let transport = OrderedInputRecordingTransport()
        let gate = OrderedInputHandlerGate()
        let connection = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                await gate.handle(request)
                return .ok(["handled": request.id ?? NSNull()])
            },
            onClose: { _ in }
        )
        // input-1 is held on surface s1; input-2 targets surface s2 and must
        // run concurrently: ordering is a per-PTY property, and one surface's
        // slow request must not block typing on another.
        let batch = try Self.framedBatch(
            [
                ("input-1", "terminal.input"),
                ("input-2", "terminal.input"),
            ],
            surfaceIDsByRequestID: [
                "input-1": "surface-1",
                "input-2": "surface-2",
            ]
        )

        await connection.debugHandleReceiveDataForTesting(batch)
        await gate.waitUntilFirstInputStarts()
        await gate.waitUntilSecondInputStarts()
        #expect(await gate.secondInputStarted())

        await gate.releaseFirstInput()
        _ = await transport.waitForResponseCount(2)
        let inputResponseIDs = await transport.responseIDs().filter {
            $0.hasPrefix("input-")
        }
        #expect(Set(inputResponseIDs) == Set(["input-1", "input-2"]))
        await connection.close(reason: "test complete")
    }

    @Test
    func stalledResponseWriteDoesNotBlockLaterOrderedInput() async throws {
        let transport = OrderedInputRecordingTransport()
        await transport.setHoldSends(true)
        let gate = OrderedInputHandlerGate()
        let connection = MobileHostConnection(
            id: UUID(),
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                await gate.handle(request)
                return .ok(["handled": request.id ?? NSNull()])
            },
            onClose: { _ in }
        )
        let batch = try Self.framedBatch([
            ("stall-1", "terminal.input"),
            ("stall-2", "terminal.input"),
        ])

        await connection.debugHandleReceiveDataForTesting(batch)

        // Both inputs must APPLY even though no response write can complete:
        // a peer that stops reading stalls the serialized writer, and input
        // application must not sit behind that stall.
        var bothHandled = false
        for _ in 0..<2_000 {
            if await gate.handledRequestCount() >= 2 {
                bothHandled = true
                break
            }
            await Task.yield()
        }
        #expect(bothHandled)
        #expect(await transport.responseIDs().isEmpty)

        await transport.setHoldSends(false)
        await transport.releaseHeldSends()
        let responses = await transport.waitForResponseCount(2)
        #expect(Set(responses) == Set(["stall-1", "stall-2"]))
        await connection.close(reason: "test complete")
    }

    private static func framedBatch(
        _ requests: [(id: String, method: String)],
        surfaceIDsByRequestID: [String: String] = [:]
    ) throws -> Data {
        var batch = Data()
        for request in requests {
            var params: [String: Any] = request.method == "terminal.input"
                ? ["text": request.id]
                : [:]
            if let surfaceID = surfaceIDsByRequestID[request.id] {
                params["surface_id"] = surfaceID
            }
            let payload: [String: Any] = [
                "id": request.id,
                "method": request.method,
                "params": params,
            ]
            batch.append(try MobileSyncFrameCodec.encodeFrame(
                JSONSerialization.data(withJSONObject: payload)
            ))
        }
        return batch
    }
}

private actor OrderedInputHandlerGate {
    private var firstInputStarted = false
    private var didSecondInputStart = false
    private var workspaceStarted = false
    private var handledCount = 0
    private var firstInputRelease: CheckedContinuation<Void, Never>?
    private var firstInputWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondInputWaiters: [CheckedContinuation<Void, Never>] = []
    private var workspaceWaiters: [CheckedContinuation<Void, Never>] = []

    func handle(_ request: MobileHostRPCRequest) async {
        handledCount += 1
        switch request.id as? String {
        case "input-1":
            firstInputStarted = true
            resume(&firstInputWaiters)
            await withCheckedContinuation { firstInputRelease = $0 }
        case "input-2":
            didSecondInputStart = true
            resume(&secondInputWaiters)
        case "workspace":
            workspaceStarted = true
            resume(&workspaceWaiters)
        default:
            break
        }
    }

    func waitUntilFirstInputStarts() async {
        if firstInputStarted { return }
        await withCheckedContinuation { firstInputWaiters.append($0) }
    }

    func waitUntilSecondInputStarts() async {
        if didSecondInputStart { return }
        await withCheckedContinuation { secondInputWaiters.append($0) }
    }

    func waitUntilWorkspaceStarts() async {
        if workspaceStarted { return }
        await withCheckedContinuation { workspaceWaiters.append($0) }
    }

    func releaseFirstInput() {
        firstInputRelease?.resume()
        firstInputRelease = nil
    }

    func secondInputStarted() -> Bool { didSecondInputStart }
    func handledRequestCount() -> Int { handledCount }

    private func resume(
        _ waiters: inout [CheckedContinuation<Void, Never>]
    ) {
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor OrderedInputRecordingTransport: CmxByteTransport {
    private var responses: [String] = []
    private var responseWaiters:
        [(Int, CheckedContinuation<[String], Never>)] = []
    private var closes = 0
    private var holdSends = false
    private var heldSendContinuations: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {}
    func receive() async throws -> Data? { nil }

    func setHoldSends(_ hold: Bool) {
        holdSends = hold
    }

    func releaseHeldSends() {
        let continuations = heldSendContinuations
        heldSendContinuations = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func send(_ data: Data) async throws {
        if holdSends {
            await withCheckedContinuation { heldSendContinuations.append($0) }
        }
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let envelope = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any]
            responses.append(envelope?["id"] as? String ?? "")
        }
        let ready = responseWaiters.filter { responses.count >= $0.0 }
        responseWaiters.removeAll { responses.count >= $0.0 }
        for (_, waiter) in ready {
            waiter.resume(returning: responses)
        }
    }

    func close() {
        closes += 1
    }

    func waitForResponseCount(_ count: Int) async -> [String] {
        if responses.count >= count { return responses }
        return await withCheckedContinuation {
            responseWaiters.append((count, $0))
        }
    }

    func responseIDs() -> [String] { responses }
    func closeCount() -> Int { closes }
}
