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


// MARK: - Terminal input + render-grid output
/// Test collector that mounts a surface's ``CMUXMobileShellStore`` output stream
/// and accumulates each chunk's UTF-8 text, mirroring what a mounted
/// `GhosttySurfaceView` would feed into libghostty.
@MainActor
final class TerminalOutputCollector {
    private(set) var lines: [String] = []
    private var task: Task<Void, Never>?

    /// Begin consuming the surface's output stream into ``lines``.
    func mount(store: CMUXMobileShellStore, surfaceID: String) {
        task = Task { @MainActor [weak self] in
            for await data in store.terminalOutputStream(surfaceID: surfaceID) {
                self?.lines.append(String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    /// Stop consuming the stream, unregistering the surface from the store.
    func unmount() {
        task?.cancel()
        task = nil
    }
}

@MainActor
@Test func submittedTerminalInputIncludesClientViewportAndCarriageReturn() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcResultFrame(result: ["accepted": true]),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID(rawValue: "live-workspace"),
        terminalID: MobileTerminalPreview.ID(rawValue: "live-terminal"),
        viewportSize: MobileTerminalViewportSize(columns: 52, rows: 24)
    )
    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.terminalInputText = "echo hi"
    await store.submitTerminalInput()

    let inputRequest = try #require(await responses.sentRequests().first { $0.method == "terminal.input" })
    #expect(inputRequest.text == "echo hi\r")
    #expect(inputRequest.viewportColumns == 52)
    #expect(inputRequest.viewportRows == 24)
    #expect(inputRequest.clientID?.isEmpty == false)
    #expect(store.terminalInputText.isEmpty)
}

@MainActor
@Test func rawTerminalInputDoesNotAppendCarriageReturn() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcResultFrame(result: ["accepted": true]),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    await store.submitTerminalRawInput("\u{1B}[A")

    let inputRequest = try #require(await responses.sentRequests().first { $0.method == "terminal.input" })
    #expect(inputRequest.text == "\u{1B}[A")
}

@MainActor
@Test func terminalInputResyncsOutputWhenMacSequenceIsAhead() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let router = TerminalOutputSelfHealingRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    collector.mount(store: store, surfaceID: "live-terminal")
    let oldGridText = try terminalRenderGridReplacementText(seq: 4, text: "old")
    let currentGridText = try terminalRenderGridReplacementText(seq: 12, text: "current")

    _ = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)
    for _ in 0..<200 where collector.lines.count < 1 {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")

    _ = try await waitForRequestCount("mobile.terminal.replay", count: 2, router: router)
    _ = try await waitForRequestCount("mobile.events.subscribe", count: 2, router: router)
    for _ in 0..<200 where collector.lines.isEmpty {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    #expect(collector.lines == [
        oldGridText,
        currentGridText,
    ])
    collector.unmount()
}

@MainActor
@Test func renderGridTerminalInputWaitsForLiveEventBeforeReplay() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let router = TerminalOutputSelfHealingRouter(renderGrid: true)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    _ = try await waitForRequestCount("mobile.events.subscribe", count: 1, router: router)
    collector.mount(store: store, surfaceID: "live-terminal")
    _ = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)

    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")
    let afterFirstInput = await router.sentRequests()
    #expect(afterFirstInput.filter { $0.method == "mobile.terminal.replay" }.count == 1)

    await store.submitTerminalRawInput(Data("y".utf8), surfaceID: "live-terminal")
    _ = try await waitForRequestCount("mobile.terminal.replay", count: 2, router: router)

    let oldGridText = try terminalRenderGridReplacementText(seq: 4, text: "old")
    let currentGridText = try terminalRenderGridReplacementText(seq: 12, text: "current")
    #expect(collector.lines == [
        oldGridText,
        currentGridText,
    ])
    collector.unmount()
}

@MainActor
@Test func terminalRenderGridEventsDriveMountedSink() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let router = TerminalRenderGridEventRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let subscribeRequests = try await waitForRequestCount("mobile.events.subscribe", count: 1, router: router)
    #expect(subscribeRequests.first?.topics == ["workspace.updated", "terminal.render_grid"])

    collector.mount(store: store, surfaceID: "live-terminal")
    _ = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)
    for _ in 0..<200 where collector.lines.count < 2 {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let liveText = try terminalRenderGridStyledReplacementText(seq: 2, text: "live")
    #expect(collector.lines == [liveText])
    #expect(liveText.contains("\u{1B}[0;1;4;38;2;255;0;0;48;2;0;0;255mlive"))
    #expect(liveText.contains("\u{1B}[6 q\u{1B}[?25h\u{1B}[2;3H"))
    collector.unmount()
}

