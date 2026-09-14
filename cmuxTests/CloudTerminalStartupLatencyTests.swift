import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the post-#12505 Cloud startup path.
@Suite("Cloud terminal startup latency")
struct CloudTerminalStartupLatencyTests {
    @Test
    func readinessRetainsReplayAndFrameUntilAttachAcknowledges() {
        var readiness = CloudTerminalStartupReadiness()
        readiness.begin(baselineFrame: 40)
        readiness.markReplayApplied()
        #expect(!readiness.markFramePresented(
            sequence: 41,
            rendererPresented: true,
            effectivelyVisible: true
        ))
        #expect(readiness.markAttached())
        #expect(readiness.isReady)
    }

    @Test
    func hiddenReadinessDoesNotClaimReadyUntilAVisibleFrame() {
        var readiness = CloudTerminalStartupReadiness()
        readiness.begin(baselineFrame: 7)
        readiness.markAttached()
        readiness.markReplayApplied()
        #expect(!readiness.markFramePresented(
            sequence: 8,
            rendererPresented: true,
            effectivelyVisible: false
        ))
        #expect(!readiness.isReady)
        #expect(readiness.markFramePresented(
            sequence: 9,
            rendererPresented: true,
            effectivelyVisible: true
        ))
    }

    @Test
    func unresolvedPaneKeepsAConnectionStatusWhileSurfaceIsResolved() {
        #expect(
            CloudManualMirrorPresentation(
                phase: .idle,
                replayReceived: false,
                rendererReady: false,
                surfaceResolutionPending: true
            ).connectionState == .connecting
        )
        #expect(
            CloudManualMirrorPresentation(
                phase: .idle,
                replayReceived: false,
                rendererReady: false
            ).connectionState == nil
        )
    }

    @Test
    func revealRequiresAFrameNewerThanTheHiddenEpisode() {
        var readiness = CloudTerminalStartupReadiness()
        readiness.begin(baselineFrame: 7)
        readiness.markAttached()
        readiness.markReplayApplied()
        readiness.beginVisiblePresentation(baselineFrame: 8)
        #expect(!readiness.markFramePresented(
            sequence: 8,
            rendererPresented: true,
            effectivelyVisible: true
        ))
        #expect(readiness.markFramePresented(
            sequence: 9,
            rendererPresented: true,
            effectivelyVisible: true
        ))
    }

    @Test
    func aFrameBeforeReplayCannotMakeTheReplayedTerminalReady() {
        var readiness = CloudTerminalStartupReadiness()
        readiness.begin(baselineFrame: 10)
        readiness.markAttached()
        readiness.markFramePresented(sequence: 11, rendererPresented: true, effectivelyVisible: true)
        #expect(!readiness.markReplayApplied())
        #expect(!readiness.isReady)
        #expect(readiness.markFramePresented(sequence: 12, rendererPresented: true, effectivelyVisible: true))
    }

    @Test @MainActor
    func unresolvedPaneShowsProgressUntilCancelledOrFailed() {
        let session = CloudTuiManualMirrorSession(
            machineID: "machine", terminalID: "term_pending", remoteSurfaceID: 0,
            onNeedsReconnect: {}
        )
        defer { session.stop() }
        #expect(session.connectionPresentation?.showsProgress == true)
        #expect(session.cancelConnectionAttempt())
        #expect(session.connectionPresentation == nil)
        #expect(session.retryConnection())
        #expect(session.connectionPresentation?.showsReconnectButton == true)
    }

    @Test @MainActor
    func quietReplayReachesAVisibleNativeFrameAndAcceptsInput() async throws {
        let app = try #require(AppDelegate.shared)
        let windowID = app.createMainWindow()
        let window = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.main.\(windowID.uuidString)"
        })
        defer { window.performClose(nil) }
        let workspace = try #require(app.tabManagerFor(windowId: windowID)?.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "fixture", terminalID: "term_quiet", remoteSurfaceID: 17,
            onNeedsReconnect: {}
        )
        defer { session.stop() }
        let router = session.inputRouter
        let created = try SurfacePaneFactory.makeCloudManualMirrorPane(
            at: .tab(workspaceID: workspace.id, paneID: pane.id.uuidString, index: nil),
            focus: true,
            onInput: { router.send($0) },
            onResize: { session.apply(size: $0) },
            onRuntimeReady: { session.runtimeReady() },
            onFocus: { session.claimGeometry() },
            attachment: session.attachmentStatus
        )
        session.bind(surface: created.surface)
        let frames = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidRenderFrame, object: created.surface.hostedView.surfaceView, queue: .main
        ) { _ in frames.continuation.yield(()) }
        defer {
            NotificationCenter.default.removeObserver(observer)
            frames.continuation.finish()
        }
        session.reconnect(socketPath: fixture.socketPath)
        for expected in ["identify", "set-client-info", "attach-surface"] {
            let command = try #require(await fixture.nextCommand(timeout: .seconds(5)))
            #expect(command.cmd == expected)
            fixture.send(["id": command.id, "ok": true, "data": ["protocol": 12, "capabilities": []]])
        }
        fixture.send([
            "event": "vt-state", "surface": 17, "cols": 80, "rows": 24,
            "data": Data("Cloud startup ready\r\n".utf8).base64EncodedString()
        ])
        let ready = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                for await _ in frames.stream {
                    if session.startupReadiness.isReady { return true }
                }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(10)) } catch { return false }
                return false
            }
            let result = await group.next() ?? false
            frames.continuation.finish()
            group.cancelAll()
            return result
        }
        try #require(ready)
        #expect(created.surface.readText(region: .viewport)?.contains("Cloud startup ready") == true)
        #expect(session.connectionPresentation == nil)
        router.send(.bytes(Data("pwd\n".utf8)))
        var sentInput = false
        for _ in 0..<10 {
            guard let command = await fixture.nextCommand(timeout: .seconds(2)) else { break }
            if command.cmd == "send" {
                #expect(command.surface == 17)
                sentInput = true
                break
            }
            fixture.send(["id": command.id, "ok": true])
        }
        #expect(sentInput)
    }

    @Test @MainActor
    func unresolvedSurfaceCannotStartAnAttachStream() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_new-machine",
            remoteSurfaceID: 0,
            onNeedsReconnect: {}
        )
        defer { session.stop() }

        session.reconnect(socketPath: fixture.socketPath)

        #expect(session.phase == .idle)
        #expect(await fixture.nextCommand(timeout: .milliseconds(200)) == nil)
    }
}
