import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit coverage for the manual-IO tui pump: relay exit classification, the
/// respawn decision, backoff pacing, the relay stdin wire format, the relay
/// argv, the overlay presentation mapping, and the cross-thread input
/// channel. All pure or pipe-local; no daemon and no app launch involved.
struct TuiManualIOPumpTests {
    // MARK: - Relay exit classification

    @Test
    func relayExitReadsTheFinalStderrJSONLine() {
        // Config warnings and other noise may precede the exit line.
        let stderrText = """
        warning: something unrelated
        {"exit":{"reason":"terminal-ended"}}
        """
        #expect(TuiManualIOPumpPolicy.relayExit(status: 0, stderrText: stderrText) == .terminalEnded)
        #expect(
            TuiManualIOPumpPolicy.relayExit(
                status: 0,
                stderrText: "{\"exit\":{\"reason\":\"parent-closed\"}}\n"
            ) == .parentClosed
        )
        #expect(
            TuiManualIOPumpPolicy.relayExit(
                status: 2,
                stderrText: "{\"exit\":{\"reason\":\"daemon-lost\"}}\n"
            ) == .daemonLost
        )
        // Exit 2 without the relay's reason line is a usage error (e.g. a
        // binary without --pipe-io), not an endlessly-retryable outage.
        #expect(TuiManualIOPumpPolicy.relayExit(status: 2, stderrText: nil) == .failure)
        #expect(
            TuiManualIOPumpPolicy.relayExit(status: 2, stderrText: "cmux: unknown argument")
                == .failure
        )
    }

    @Test
    func relayExitTreatsUnknownStatusAsFailureAndBareZeroAsEnded() {
        // Exit 0 with no reason line: the relay contract says 0 means "do
        // not respawn", so a missing line must not turn into a retry loop.
        #expect(TuiManualIOPumpPolicy.relayExit(status: 0, stderrText: nil) == .terminalEnded)
        #expect(TuiManualIOPumpPolicy.relayExit(status: 0, stderrText: "garbage") == .terminalEnded)
        #expect(TuiManualIOPumpPolicy.relayExit(status: 1, stderrText: "usage: ...") == .failure)
        #expect(TuiManualIOPumpPolicy.relayExit(status: -1, stderrText: nil) == .failure)
    }

    @Test
    func nextActionRespawnsOnlyForRecoverableExits() {
        #expect(TuiManualIOPumpPolicy.nextAction(after: .terminalEnded) == .end)
        #expect(TuiManualIOPumpPolicy.nextAction(after: .daemonLost) == .retry)
        #expect(TuiManualIOPumpPolicy.nextAction(after: .failure) == .retry)
        // The pump closed stdin itself (teardown/respawn): never a state
        // transition of its own.
        #expect(TuiManualIOPumpPolicy.nextAction(after: .parentClosed) == .ignore)
    }

    // MARK: - Backoff

    @Test
    func retryDelayGrowsAndCaps() {
        #expect(TuiManualIOPumpPolicy.retryDelay(attempt: 1) == .milliseconds(500))
        #expect(TuiManualIOPumpPolicy.retryDelay(attempt: 2) == .seconds(1))
        #expect(TuiManualIOPumpPolicy.retryDelay(attempt: 6) == .seconds(16))
        #expect(TuiManualIOPumpPolicy.retryDelay(attempt: 7) == .seconds(30))
        #expect(TuiManualIOPumpPolicy.retryDelay(attempt: 100) == .seconds(30))
        #expect(TuiManualIOPumpPolicy.retryDelay(attempt: 0) == .milliseconds(500))
    }

    // MARK: - Relay stdin wire format

    @Test
    func inputLineIsBase64JSONWithTrailingNewline() throws {
        let line = TuiManualIOPumpPolicy.inputLine(bytes: Data("hi".utf8))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        let object = try JSONSerialization.jsonObject(
            with: Data(text.dropLast().utf8)
        ) as? [String: Any]
        #expect(object?["input"] as? String == "aGk=")
    }

    @Test
    func resizeLineCarriesClampedGrid() throws {
        let line = TuiManualIOPumpPolicy.resizeLine(cols: 120, rows: 0)
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        let object = try JSONSerialization.jsonObject(
            with: Data(text.dropLast().utf8)
        ) as? [String: Any]
        let resize = object?["resize"] as? [String: Any]
        #expect(resize?["cols"] as? Int == 120)
        #expect(resize?["rows"] as? Int == 1)
    }

    // MARK: - Relay argv

    @Test
    func relayArgumentsAreDirectArgvWithoutShellQuoting() {
        let arguments = TuiManualIOPumpPolicy.relayArguments(
            sessionName: "cmux-tag",
            terminalID: "term_abc",
            cols: 100,
            rows: 30
        )
        #expect(arguments == [
            "attach", "--session", "cmux-tag", "--terminal", "term_abc",
            "--pipe-io", "--cols", "100", "--rows", "30",
        ])
    }

    @Test
    func resyncResetIsFullResetPlusScrollbackErase() {
        #expect(TuiManualIOPumpPolicy.resyncReset == Data("\u{1B}c\u{1B}[3J".utf8))
    }

    // MARK: - Overlay presentation

    @Test
    func overlayIsHiddenWhileConnectingOrLive() {
        #expect(TuiManualIOPumpPolicy.overlayPresentation(state: .connecting) == nil)
        #expect(TuiManualIOPumpPolicy.overlayPresentation(state: .live) == nil)
    }

    @Test
    func reconnectingOverlayShowsProgressAndRetryButton() throws {
        let presentation = try #require(
            TuiManualIOPumpPolicy.overlayPresentation(state: .reconnecting(attempt: 3))
        )
        #expect(presentation.showsProgress)
        #expect(presentation.showsReconnectButton)
        #expect(presentation.detail.contains("3"))
    }

    @Test
    func endedOverlayIsInformationalOnly() throws {
        let presentation = try #require(
            TuiManualIOPumpPolicy.overlayPresentation(state: .ended)
        )
        #expect(!presentation.showsProgress)
        #expect(!presentation.showsReconnectButton)
    }

    @Test
    func failedOverlayOffersManualRetryOnly() throws {
        let presentation = try #require(
            TuiManualIOPumpPolicy.overlayPresentation(state: .failed)
        )
        #expect(!presentation.showsProgress)
        #expect(presentation.showsReconnectButton)
    }

    // MARK: - Input channel

    @Test
    func inputChannelWritesToTheLiveHandleAndDropsWhenPaused() throws {
        let pipe = Pipe()
        let channel = TuiManualIOInputChannel()
        channel.setHandle(pipe.fileHandleForWriting)
        channel.send(Data("first\n".utf8))
        // Pause (relay died): input is dropped, never queued for a future
        // relay, so stale keystrokes cannot replay into a resynced shell.
        channel.setHandle(nil)
        channel.send(Data("dropped\n".utf8))
        channel.setHandle(pipe.fileHandleForWriting)
        channel.send(Data("second\n".utf8))
        channel.closeHandle()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: data, as: UTF8.self) == "first\nsecond\n")
    }

    // MARK: - Registry

    @MainActor
    @Test
    func registryReplacesAndRemovesPumps() {
        let registry = TuiManualIOPumpRegistry()
        let surfaceID = UUID()
        let first = TuiManualIOPump(
            binaryPath: "/nonexistent",
            sessionName: "cmux-test",
            terminalID: "term_1",
            environment: [:]
        )
        let second = TuiManualIOPump(
            binaryPath: "/nonexistent",
            sessionName: "cmux-test",
            terminalID: "term_2",
            environment: [:]
        )
        registry.register(first, surfaceID: surfaceID)
        #expect(registry.pump(forSurfaceID: surfaceID) === first)
        registry.register(second, surfaceID: surfaceID)
        #expect(registry.pump(forSurfaceID: surfaceID) === second)
        registry.stopAndRemove(surfaceID: surfaceID)
        #expect(registry.pump(forSurfaceID: surfaceID) == nil)
    }
}
