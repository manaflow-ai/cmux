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


// MARK: - Scenario routers for request-aware transports
actor DelayedManualAttachTicketRouter: RequestAwareTransportRouter {
    private let route: CmxAttachRoute
    private var attachTicketRequested = false
    private var attachTicketReleased = false
    private var attachTicketRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var attachTicketReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    init(route: CmxAttachRoute) {
        self.route = route
    }

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func waitForAttachTicketRequest() async {
        guard !attachTicketRequested else { return }
        await withCheckedContinuation { continuation in
            attachTicketRequestWaiters.append(continuation)
        }
    }

    func releaseAttachTicketResponse() {
        attachTicketReleased = true
        attachTicketReleaseContinuation?.resume()
        attachTicketReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "mobile.attach_ticket.create":
            markAttachTicketRequested()
            await waitForAttachTicketRelease()
            return try rpcAttachTicketFrame(route: route, workspaceID: "delayed-workspace")
        case "workspace.list":
            return try rpcWorkspaceListFrame(workspaceID: "delayed-workspace", title: "Delayed Workspace")
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markAttachTicketRequested() {
        attachTicketRequested = true
        let waiters = attachTicketRequestWaiters
        attachTicketRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForAttachTicketRelease() async {
        guard !attachTicketReleased else { return }
        await withCheckedContinuation { continuation in
            attachTicketReleaseContinuation = continuation
        }
    }
}

actor SupersededAttachURLRouter: RequestAwareTransportRouter {
    private var workspaceListRequestCount = 0
    private var firstWorkspaceListRequested = false
    private var firstWorkspaceListReleased = false
    private var firstWorkspaceListRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWorkspaceListReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func waitForFirstWorkspaceListRequest() async {
        guard !firstWorkspaceListRequested else { return }
        await withCheckedContinuation { continuation in
            firstWorkspaceListRequestWaiters.append(continuation)
        }
    }

    func releaseFirstWorkspaceListResponse() {
        firstWorkspaceListReleased = true
        firstWorkspaceListReleaseContinuation?.resume()
        firstWorkspaceListReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            workspaceListRequestCount += 1
            if workspaceListRequestCount == 1 {
                markFirstWorkspaceListRequested()
                await waitForFirstWorkspaceListRelease()
                return try rpcWorkspaceListFrame(
                    workspaceID: "first-workspace",
                    title: "First Workspace",
                    terminalID: "first-terminal"
                )
            }
            return try rpcWorkspaceListFrame(
                workspaceID: "second-workspace",
                title: "Second Workspace",
                terminalID: "second-terminal"
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markFirstWorkspaceListRequested() {
        firstWorkspaceListRequested = true
        let waiters = firstWorkspaceListRequestWaiters
        firstWorkspaceListRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForFirstWorkspaceListRelease() async {
        guard !firstWorkspaceListReleased else { return }
        await withCheckedContinuation { continuation in
            firstWorkspaceListReleaseContinuation = continuation
        }
    }
}

actor RemoteCreateTerminalRouter: RequestAwareTransportRouter {
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcTwoWorkspaceListFrame()
        case "terminal.create":
            return try rpcTerminalCreateScopedFrame()
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

actor DelayedRemoteCreateTerminalRouter: RequestAwareTransportRouter {
    private var terminalCreateRequested = false
    private var terminalCreateReleased = false
    private var terminalCreateRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalCreateReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func waitForTerminalCreateRequest() async {
        guard !terminalCreateRequested else { return }
        await withCheckedContinuation { continuation in
            terminalCreateRequestWaiters.append(continuation)
        }
    }

    func releaseTerminalCreateResponse() {
        terminalCreateReleased = true
        terminalCreateReleaseContinuation?.resume()
        terminalCreateReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcTwoWorkspaceListFrame()
        case "terminal.create":
            markTerminalCreateRequested()
            await waitForTerminalCreateRelease()
            return try rpcTerminalCreateScopedFrame()
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markTerminalCreateRequested() {
        terminalCreateRequested = true
        let waiters = terminalCreateRequestWaiters
        terminalCreateRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForTerminalCreateRelease() async {
        guard !terminalCreateReleased else { return }
        await withCheckedContinuation { continuation in
            terminalCreateReleaseContinuation = continuation
        }
    }
}

actor RemoteCreateWorkspaceRouter: RequestAwareTransportRouter {
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: "workspace-main",
                title: "cmux",
                terminalID: "terminal-build"
            )
        case "workspace.create":
            return try rpcWorkspaceCreateFrame()
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

actor TerminalOutputSelfHealingRouter: RequestAwareTransportRouter {
    private let renderGrid: Bool
    private var requests: [RecordedRPCRequest] = []
    private var replayCount = 0

    init(renderGrid: Bool = false) {
        self.renderGrid = renderGrid
    }

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: "live-workspace",
                title: "Live Workspace",
                terminalID: "live-terminal"
            )
        case "mobile.host.status":
            return try rpcHostStatusFrame(renderGrid: renderGrid)
        case "mobile.events.subscribe":
            return try rpcResultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.replay":
            replayCount += 1
            if replayCount == 1 {
                return try rpcTerminalReplayFrame(
                    seq: 4,
                    rawText: "stale-old-tail",
                    snapshotText: "old",
                    renderGridText: "old"
                )
            }
            return try rpcTerminalReplayFrame(
                seq: 12,
                rawText: "stale-current-tail",
                snapshotText: "current",
                renderGridText: "current"
            )
        case "terminal.input":
            return try rpcResultFrame(
                result: [
                    "workspace_id": "live-workspace",
                    "surface_id": "live-terminal",
                    "queued": false,
                    "terminal_seq": 12,
                ]
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

actor TerminalRenderGridEventRouter: RequestAwareTransportRouter {
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: "live-workspace",
                title: "Live Workspace",
                terminalID: "live-terminal"
            )
        case "mobile.host.status":
            return try rpcHostStatusFrame(renderGrid: true)
        case "mobile.events.subscribe":
            return try rpcResultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.replay":
            return try combinedFrames([
                rpcTerminalReplayFrame(
                    seq: 1,
                    rawText: "unused-tail",
                    renderGridText: "initial"
                ),
                terminalRenderGridEventFrame(seq: 2, text: "live", styled: true),
            ])
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

