import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobilePairedMac
import CmuxMobileRPC
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI
import CmuxMobileShellModel
import CmuxMobileWorkspace
import Foundation
import StackAuth
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import cmuxFeature


// MARK: - Transport factories + scripted/failing/hanging transports
struct ScriptedTransportFactory: CmxByteTransportFactory {
    let responses: ScriptedTransportResponses

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        ScriptedTransport(responses: responses)
    }
}

struct FailingRouteTransportFactory: CmxByteTransportFactory {
    let failingRouteID: String
    let responses: ScriptedTransportResponses
    let attempts: RouteAttemptRecorder

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        FailingRouteTransport(
            routeID: route.id,
            failingRouteID: failingRouteID,
            responses: responses,
            attempts: attempts
        )
    }
}

protocol RequestAwareTransportRouter: Actor {
    func record(_ request: RecordedRPCRequest)
    func sentRequests() -> [RecordedRPCRequest]
    func response(for request: RecordedRPCRequest) async throws -> Data?
}

struct RequestAwareTransportFactory: CmxByteTransportFactory {
    let router: any RequestAwareTransportRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        RequestAwareTransport(router: router)
    }
}

private actor RequestAwareTransport: CmxByteTransport {
    private let router: any RequestAwareTransportRouter
    private var pendingResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: any RequestAwareTransportRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let request = try recordedRPCRequest(from: payload)
            await router.record(request)
            // Process each request concurrently so a router that blocks one
            // request (e.g. a delayed terminal.create) doesn't head-of-line
            // block subsequent RPCs the persistent transport sends. Matches
            // the Mac-side semantics we'd want once respond() goes
            // concurrent on a single connection.
            Task { [router, weak self] in
                guard let response = try? await router.response(for: request) else {
                    return
                }
                guard let stamped = try? responseFrame(response, matching: request) else {
                    return
                }
                await self?.deliver(stamped)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ response: Data) {
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        } else {
            pendingResponses.append(response)
        }
    }
}

actor RouteAttemptRecorder {
    private var recordedRouteIDs: [String] = []

    func record(_ routeID: String) {
        recordedRouteIDs.append(routeID)
    }

    func routeIDs() -> [String] {
        recordedRouteIDs
    }
}

actor ScriptedTransportResponses {
    private var frames: [Data]
    private var sentPayloads: [Data] = []

    init(_ frames: [Data]) {
        self.frames = frames
    }

    func recordSend(_ data: Data) throws -> [Data] {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        var responses: [Data] = []
        for payload in payloads {
            sentPayloads.append(payload)
            guard !frames.isEmpty else {
                continue
            }
            let request = try recordedRPCRequest(from: payload)
            let response = try responseFrame(frames.removeFirst(), matching: request)
            responses.append(response)
        }
        return responses
    }

    func hasRemainingFrames() -> Bool {
        !frames.isEmpty
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map { payload in
            let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let params = request["params"] as? [String: Any] ?? [:]
            let auth = request["auth"] as? [String: Any]
            return RecordedRPCRequest(
                id: request["id"] as? String,
                method: request["method"] as? String,
                workspaceID: params["workspace_id"] as? String,
                terminalID: params["terminal_id"] as? String ??
                    params["surface_id"] as? String ??
                    params["tab_id"] as? String,
                viewportColumns: params["viewport_columns"] as? Int,
                viewportRows: params["viewport_rows"] as? Int,
                maxScrollbackRows: params["max_scrollback_rows"] as? Int,
                clientID: params["client_id"] as? String,
                text: params["text"] as? String,
                topics: params["topics"] as? [String],
                hasAuth: auth != nil,
                attachToken: auth?["attach_token"] as? String,
                stackAccessToken: auth?["stack_access_token"] as? String
            )
        }
    }
}

struct RecordedRPCRequest: Sendable {
    var id: String?
    var method: String?
    var workspaceID: String?
    var terminalID: String?
    var viewportColumns: Int?
    var viewportRows: Int?
    var maxScrollbackRows: Int?
    var clientID: String?
    var text: String?
    var topics: [String]?
    var hasAuth: Bool
    var attachToken: String?
    var stackAccessToken: String?
}

private func recordedRPCRequest(from payload: Data) throws -> RecordedRPCRequest {
    let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let params = request["params"] as? [String: Any] ?? [:]
    let auth = request["auth"] as? [String: Any]
    return RecordedRPCRequest(
        id: request["id"] as? String,
        method: request["method"] as? String,
        workspaceID: params["workspace_id"] as? String,
        terminalID: params["terminal_id"] as? String ?? params["surface_id"] as? String,
        viewportColumns: params["viewport_columns"] as? Int,
        viewportRows: params["viewport_rows"] as? Int,
        maxScrollbackRows: params["max_scrollback_rows"] as? Int,
        clientID: params["client_id"] as? String,
        text: params["text"] as? String,
        topics: params["topics"] as? [String],
        hasAuth: auth != nil,
        attachToken: auth?["attach_token"] as? String,
        stackAccessToken: auth?["stack_access_token"] as? String
    )
}

private actor ScriptedTransport: CmxByteTransport {
    private let responses: ScriptedTransportResponses
    private var pendingResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var inFlightSends = 0
    private var isClosed = false

    init(responses: ScriptedTransportResponses) {
        self.responses = responses
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        await nextResponse()
    }

    func send(_ data: Data) async throws {
        inFlightSends += 1
        let responseFrames: [Data]
        do {
            responseFrames = try await responses.recordSend(data)
        } catch {
            inFlightSends -= 1
            await finishExhaustedReceiversIfIdle()
            throw error
        }
        for frame in responseFrames {
            enqueue(frame)
        }
        inFlightSends -= 1
        await finishExhaustedReceiversIfIdle()
    }

    func close() async {
        closeLocal()
    }

    private func nextResponse() async -> Data? {
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
        }
        if isClosed {
            return nil
        }
        if inFlightSends > 0 {
            return await waitForResponse()
        }
        guard await responses.hasRemainingFrames() else {
            return nil
        }
        return await waitForResponse()
    }

    private func waitForResponse() async -> Data? {
        await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    private func enqueue(_ response: Data) {
        if receiveWaiters.isEmpty {
            pendingResponses.append(response)
        } else {
            let waiter = receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        }
    }

    private func finishExhaustedReceiversIfIdle() async {
        guard inFlightSends == 0, pendingResponses.isEmpty, !(await responses.hasRemainingFrames()) else {
            return
        }
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func closeLocal() {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

private enum FailingRouteTransportError: Error {
    case connectFailed
}

private actor FailingRouteTransport: CmxByteTransport {
    private let routeID: String
    private let failingRouteID: String
    private let responses: ScriptedTransportResponses
    private let attempts: RouteAttemptRecorder
    private var pendingResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var inFlightSends = 0
    private var isClosed = false

    init(
        routeID: String,
        failingRouteID: String,
        responses: ScriptedTransportResponses,
        attempts: RouteAttemptRecorder
    ) {
        self.routeID = routeID
        self.failingRouteID = failingRouteID
        self.responses = responses
        self.attempts = attempts
    }

    func connect() async throws {
        await attempts.record(routeID)
        if routeID == failingRouteID {
            throw FailingRouteTransportError.connectFailed
        }
    }

    func receive() async throws -> Data? {
        await nextResponse()
    }

    func send(_ data: Data) async throws {
        inFlightSends += 1
        let responseFrames: [Data]
        do {
            responseFrames = try await responses.recordSend(data)
        } catch {
            inFlightSends -= 1
            await finishExhaustedReceiversIfIdle()
            throw error
        }
        for frame in responseFrames {
            enqueue(frame)
        }
        inFlightSends -= 1
        await finishExhaustedReceiversIfIdle()
    }

    func close() async {
        closeLocal()
    }

    private func nextResponse() async -> Data? {
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
        }
        if isClosed {
            return nil
        }
        if inFlightSends > 0 {
            return await waitForResponse()
        }
        guard await responses.hasRemainingFrames() else {
            return nil
        }
        return await waitForResponse()
    }

    private func waitForResponse() async -> Data? {
        await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    private func enqueue(_ response: Data) {
        if receiveWaiters.isEmpty {
            pendingResponses.append(response)
        } else {
            let waiter = receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        }
    }

    private func finishExhaustedReceiversIfIdle() async {
        guard inFlightSends == 0, pendingResponses.isEmpty, !(await responses.hasRemainingFrames()) else {
            return
        }
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func closeLocal() {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

private func responseFrame(_ data: Data, matching request: RecordedRPCRequest) throws -> Data {
    guard let requestID = request.id else {
        return data
    }
    var buffer = data
    let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
    guard !frames.isEmpty else {
        return data
    }
    var encoded = Data()
    for frame in frames {
        guard var envelope = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            encoded.append(try MobileSyncFrameCodec.encodeFrame(frame))
            continue
        }
        envelope["id"] = requestID
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        encoded.append(try MobileSyncFrameCodec.encodeFrame(envelopeData))
    }
    return encoded
}

func combinedFrames(_ frames: [Data]) -> Data {
    frames.reduce(into: Data()) { output, frame in
        output.append(frame)
    }
}

struct HangingTransportFactory: CmxByteTransportFactory {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        HangingTransport()
    }
}

private actor HangingTransport: CmxByteTransport {
    func connect() async throws {}

    func receive() async throws -> Data? {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        return nil
    }

    func send(_ data: Data) async throws {}

    func close() async {}
}

func rpcResultFrame(result: [String: Any]) throws -> Data {
    let envelope: [String: Any] = [
        "id": UUID().uuidString,
        "ok": true,
        "result": result,
    ]
    let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
    return try MobileSyncFrameCodec.encodeFrame(envelopeData)
}

func rpcErrorFrame(code: String? = nil, message: String) throws -> Data {
    var error: [String: Any] = [
        "message": message,
    ]
    if let code {
        error["code"] = code
    }
    let envelope: [String: Any] = [
        "id": UUID().uuidString,
        "ok": false,
        "error": error,
    ]
    let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
    return try MobileSyncFrameCodec.encodeFrame(envelopeData)
}
