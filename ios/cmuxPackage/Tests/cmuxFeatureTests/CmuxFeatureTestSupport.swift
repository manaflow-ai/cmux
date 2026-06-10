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


// MARK: - Shared test fixtures: runtime builders, RPC frames, wait helpers
private struct MissingTestStackAccessToken: Error {}

func testRuntime(
    supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback, .websocket],
    transportFactory: any CmxByteTransportFactory,
    stackAccessToken: String? = "test-stack-token",
    rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
    pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
    now: @escaping @Sendable () -> Date = Date.init,
    supportsServerPushEvents: Bool = false
) -> CMUXMobileRuntime {
    // Tests script every response and assert on exact request order, so by
    // default they opt out of background subscribe/poll refreshes. New tests
    // that exercise the event path should pass `supportsServerPushEvents: true`.
    CMUXMobileRuntime(
        supportedRouteKinds: supportedRouteKinds,
        transportFactory: transportFactory,
        stackAccessTokenProvider: {
            guard let stackAccessToken else {
                throw MissingTestStackAccessToken()
            }
            return stackAccessToken
        },
        rpcRequestTimeoutNanoseconds: rpcRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: pairingRequestTimeoutNanoseconds,
        now: now,
        supportsServerPushEvents: supportsServerPushEvents
    )
}

func attachURL(for ticket: CmxAttachTicket) throws -> URL {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = base64URLEncode(try encoder.encode(ticket))
    return try #require(URL(string: "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"))
}

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func scriptedWorkspaceListResponses(
    workspaceID: String,
    title: String
) throws -> ScriptedTransportResponses {
    ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: workspaceID, title: title),
    ])
}

func waitForWorkspaceListRequestCount(
    _ count: Int,
    responses: ScriptedTransportResponses
) async throws -> [RecordedRPCRequest] {
    var workspaceLists: [RecordedRPCRequest] = []
    for _ in 0..<200 {
        workspaceLists = try await responses.sentRequests().filter { $0.method == "workspace.list" }
        if workspaceLists.count >= count {
            return workspaceLists
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return workspaceLists
}

func waitForRequestCount(
    _ method: String,
    count: Int,
    router: any RequestAwareTransportRouter
) async throws -> [RecordedRPCRequest] {
    var matches: [RecordedRPCRequest] = []
    for _ in 0..<300 {
        matches = await router.sentRequests().filter { $0.method == method }
        if matches.count >= count {
            return matches
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return matches
}

@MainActor
func waitForWorkspaceIDs(
    in store: CMUXMobileShellStore,
    matching expectedIDs: [String]
) async throws -> [String] {
    var workspaceIDs: [String] = []
    for _ in 0..<200 {
        workspaceIDs = store.workspaces.map(\.id.rawValue)
        if workspaceIDs == expectedIDs {
            return workspaceIDs
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return workspaceIDs
}

func rpcWorkspaceListFrame(
    workspaceID: String,
    title: String,
    terminalID: String? = nil
) throws -> Data {
    let terminals: [[String: Any]]
    if let terminalID {
        terminals = [
            [
                "id": terminalID,
                "title": "Terminal",
                "current_directory": "/Users/test/project",
                "is_ready": true,
                "is_focused": true,
            ],
        ]
    } else {
        terminals = []
    }
    return try rpcResultFrame(
        result: [
            "workspaces": [
                [
                    "id": workspaceID,
                    "title": title,
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": terminals,
                ],
            ],
        ]
    )
}

func terminalRenderGridReplacementText(seq: UInt64, text: String) throws -> String {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "live-terminal",
        stateSeq: seq,
        columns: 16,
        rows: 4,
        text: text
    )
    return try #require(String(data: frame.vtReplacementBytes(), encoding: .utf8))
}

func terminalRenderGridStyledReplacementText(seq: UInt64, text: String) throws -> String {
    let frame = try terminalRenderGridStyledFrame(seq: seq, text: text)
    return try #require(String(data: frame.vtReplacementBytes(), encoding: .utf8))
}

private func terminalRenderGridStyledFrame(seq: UInt64, text: String) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: "live-terminal",
        stateSeq: seq,
        columns: 16,
        rows: 4,
        cursor: .init(row: 1, column: 2, style: .bar),
        styles: [
            .init(id: 0, foreground: "#C0C0C0", background: "#101010"),
            .init(id: 1, foreground: "#FF0000", background: "#0000FF", bold: true, underline: true),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: text),
        ]
    )
}

func rpcHostStatusFrame(renderGrid: Bool) throws -> Data {
    let capabilities = renderGrid
        ? ["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1"]
        : ["events.v1", "terminal.bytes.v1", "terminal.replay.v1"]
    return try rpcResultFrame(
        result: [
            "terminal_fidelity": renderGrid ? "render_grid" : "ghostty_bytes",
            "capabilities": capabilities,
        ]
    )
}

func terminalRenderGridEventFrame(seq: UInt64, text: String, styled: Bool = false) throws -> Data {
    let frame = if styled {
        try terminalRenderGridStyledFrame(seq: seq, text: text)
    } else {
        try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "live-terminal",
            stateSeq: seq,
            columns: 16,
            rows: 4,
            text: text
        )
    }
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
    return try MobileSyncFrameCodec.encodeFrame(envelopeData)
}

func rpcTerminalReplayFrame(
    seq: UInt64,
    rawText: String,
    snapshotText: String? = nil,
    renderGridText: String? = nil
) throws -> Data {
    var result: [String: Any] = [
        "workspace_id": "live-workspace",
        "surface_id": "live-terminal",
        "seq": NSNumber(value: seq),
        "data_b64": Data(rawText.utf8).base64EncodedString(),
        "columns": 16,
        "rows": 4,
    ]
    if let snapshotText {
        result["snapshot_format"] = "ghostty.active.vt"
        result["snapshot_data_b64"] = Data(snapshotText.utf8).base64EncodedString()
    }
    if let renderGridText {
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "live-terminal",
            stateSeq: seq,
            columns: 16,
            rows: 4,
            text: renderGridText
        )
        result["render_grid"] = try frame.jsonObject()
    }
    return try rpcResultFrame(
        result: result
    )
}

func rpcWorkspaceCreateFrame() throws -> Data {
    try rpcResultFrame(
        result: [
            "created_workspace_id": "workspace-3",
            "workspaces": [
                [
                    "id": "workspace-3",
                    "title": "Workspace 3",
                    "current_directory": "/Users/test/workspace-3",
                    "is_selected": true,
                    "terminals": [
                        [
                            "id": "workspace-3-terminal-1",
                            "title": "Terminal 1",
                            "current_directory": "/Users/test/workspace-3",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ],
            ],
        ]
    )
}

func rpcTwoWorkspaceListFrame() throws -> Data {
    try rpcResultFrame(
        result: [
            "workspaces": [
                [
                    "id": "workspace-main",
                    "title": "cmux",
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": [
                        [
                            "id": "terminal-build",
                            "title": "Build",
                            "current_directory": "/Users/test/project",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ],
                [
                    "id": "workspace-docs",
                    "title": "Docs",
                    "current_directory": "/Users/test/docs",
                    "is_selected": false,
                    "terminals": [
                        [
                            "id": "terminal-notes",
                            "title": "Notes",
                            "current_directory": "/Users/test/docs",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ],
            ],
        ]
    )
}

func rpcTerminalCreateScopedFrame() throws -> Data {
    try rpcResultFrame(
        result: [
            "created_terminal_id": "workspace-main-terminal-2",
            "workspaces": [
                [
                    "id": "workspace-main",
                    "title": "cmux",
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": [
                        [
                            "id": "terminal-build",
                            "title": "Build",
                            "current_directory": "/Users/test/project",
                            "is_ready": true,
                            "is_focused": false,
                        ],
                        [
                            "id": "workspace-main-terminal-2",
                            "title": "Terminal 2",
                            "current_directory": "/Users/test/project",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ],
            ],
        ]
    )
}

func rpcAttachTicketFrame(
    route: CmxAttachRoute,
    workspaceID: String,
    terminalID: String? = nil
) throws -> Data {
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: nil,
        routes: [route],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        authToken: "ticket-secret"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let ticketObject = try JSONSerialization.jsonObject(with: encoder.encode(ticket))
    return try rpcResultFrame(result: ["ticket": ticketObject])
}

func hostPortRoute(
    kind: CmxAttachTransportKind,
    host: String,
    port: Int,
    priority: Int = 0
) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: kind.rawValue,
        kind: kind,
        endpoint: .hostPort(host: host, port: port),
        priority: priority
    )
}

