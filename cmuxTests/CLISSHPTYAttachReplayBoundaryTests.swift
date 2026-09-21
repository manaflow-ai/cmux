import Darwin
import Foundation
import Testing

/// Exercises the real CLI/bridge boundary where a persistent attach declares
/// that historical PTY output is still being replayed.
@Suite(.serialized)
struct CLISSHPTYAttachReplayBoundaryTests {
    @Test
    func bridgeStopIsIdempotentAfterServerExit() throws {
        let bridge = try CLISSHPTYAttachBridgeServer { _ in }

        #expect(bridge.stop())
        #expect(bridge.stop())
    }

    @Test
    func inputTypedDuringReplayIsDiscardedBeforeForwarding() throws {
        // The CLI writes bridge output to the terminal only after every setup
        // step that precedes replay, so the mode seen once the replay head is
        // on screen is the mode the attach holds until the replay completes.
        let replayHead = "remote-"
        let replayTail = "prompt$ "
        let releaseReplayTail = DispatchSemaphore(value: 0)
        let forwardedCaptured = DispatchSemaphore(value: 0)
        let finishBridge = DispatchSemaphore(value: 0)
        let forwarded = ForwardedInput()

        try withSSHPTYAttach(requireExisting: true) { bridge in
            guard bridge.sendReady(replayBytes: (replayHead + replayTail).utf8.count),
                  bridge.send(replayHead),
                  bridge.wait(for: releaseReplayTail),
                  bridge.send(replayTail) else { return }
            // The CLI forwards input in order, so a leaked line typed during
            // replay would arrive here ahead of the safe one.
            forwarded.append(bridge.receive(timeoutMilliseconds: 5_000) { $0.contains(0x0A) })
            forwardedCaptured.signal()
            _ = bridge.wait(for: finishBridge)
        } body: { attach in
            try #require(attach.output.waitForOutput(containing: replayHead))
            // Mid-replay, signal keys stay live and typed bytes stay local.
            #expect(isDisconnectedMode(fd: attach.slaveFD))
            try #require(attach.write("dangerous-command\n"))

            releaseReplayTail.signal()
            try #require(waitUntil { isRawForwardingMode(fd: attach.slaveFD) })
            try #require(attach.write("safe-command\n"))
            try #require(forwardedCaptured.wait(timeout: .now() + 10) == .success)
            #expect(forwarded.text == "safe-command\n", Comment(rawValue: forwarded.text))

            finishBridge.signal()
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 0, Comment(rawValue: attach.stderrText))
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test
    func freshAttachForwardsKeystrokesBeforeNewline() throws {
        // A fresh attach declares no replay, so its first bridge output is
        // live. The CLI writes it only after setting up terminal input, so
        // the marker on screen means the attach has settled on its mode.
        let liveMarker = "live-prompt$ "
        let keystrokeWritten = DispatchSemaphore(value: 0)
        let keystrokeChecked = DispatchSemaphore(value: 0)
        let finishBridge = DispatchSemaphore(value: 0)
        let forwarded = ForwardedInput()

        try withSSHPTYAttach(requireExisting: false) { bridge in
            guard bridge.sendReady(replayBytes: 0),
                  bridge.send(liveMarker),
                  bridge.wait(for: keystrokeWritten) else { return }
            forwarded.append(bridge.receive(timeoutMilliseconds: 5_000) { $0.contains(UInt8(ascii: "k")) })
            keystrokeChecked.signal()
            _ = bridge.wait(for: finishBridge)
        } body: { attach in
            try #require(attach.output.waitForOutput(containing: liveMarker))
            #expect(isRawForwardingMode(fd: attach.slaveFD))

            // Raw forwarding hands each keystroke to the bridge immediately.
            // Canonical mode would echo it locally and hold it until a newline.
            try #require(attach.write("k"))
            keystrokeWritten.signal()
            try #require(keystrokeChecked.wait(timeout: .now() + 10) == .success)
            #expect(forwarded.text == "k", Comment(rawValue: forwarded.text))
            #expect(isRawForwardingMode(fd: attach.slaveFD))

            finishBridge.signal()
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 0, Comment(rawValue: attach.stderrText))
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test(arguments: [BundledCLITestSupport.appVersion + "-incompatible", "", "0.0.0-incompatible"])
    func incompatibleDaemonLeavesCallerInputUntouched(version: String) throws {
        let requestSeen = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        let retired = ForwardedInput()
        defer { releaseResponse.signal() }
        try withSSHPTYAttach(
            requireExisting: true,
            daemonVersion: version.isEmpty ? nil : version,
            beforeBridgeResponse: {
                requestSeen.signal()
                _ = releaseResponse.wait(timeout: .now() + 5)
            },
            onRequest: { method, params in
                if params["acknowledge_lifecycle"] as? Bool == true || method == "workspace.remote.pty_attach_end" {
                    retired.append(Data(method.utf8))
                }
            }
        ) { bridge in
            Issue.record("Incompatible daemon must be rejected before connecting the PTY bridge")
            _ = bridge.sendReady(replayBytes: 0)
        } body: { attach in
            try #require(requestSeen.wait(timeout: .now() + 5) == .success)
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
            try #require(attach.write("queued-input\n"))
            releaseResponse.signal()
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 1)
            #expect(attach.stderrText.contains("matching remote daemon"))
            #expect(retired.text.isEmpty)
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
            var queued = [UInt8](repeating: 0, count: 128)
            _ = fcntl(attach.slaveFD, F_SETFL, O_NONBLOCK)
            let count = Darwin.read(attach.slaveFD, &queued, queued.count)
            #expect(count > 0)
            #expect(String(decoding: queued.prefix(max(0, count)), as: UTF8.self) == "queued-input\n")
        }
    }

    @Test(arguments: [false, true])
    func controlInputArrivesWithoutEchoOrDuplication(requireExisting: Bool) throws {
        let bytes = "\u{1B}[A\t\u{03}\u{1B}[200~first line\nsecond line\u{1B}[201~"
        let captured = ForwardedInput()
        let inputReceived = DispatchSemaphore(value: 0)
        let close = DispatchSemaphore(value: 0)
        try withSSHPTYAttach(requireExisting: requireExisting) { bridge in
            guard bridge.sendReady(replayBytes: 0), bridge.send("live-ready") else { return }
            captured.append(bridge.receive(timeoutMilliseconds: 5_000) { $0.count >= bytes.utf8.count })
            inputReceived.signal()
            _ = bridge.wait(for: close)
        } body: { attach in
            try #require(attach.output.waitForOutput(containing: "live-ready"))
            #expect(isRawForwardingMode(fd: attach.slaveFD))
            try #require(attach.write(bytes))
            try #require(inputReceived.wait(timeout: .now() + 6) == .success)
            #expect(captured.text == bytes)
            close.signal()
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 0)
            #expect(attach.output.text == "live-ready")
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test
    func freshStartupQueryReplySurvivesReplayBoundary() throws {
        let reply = "\u{1B}[?1;2c\u{1B}P>|tmux-test\u{1B}\\"
        let releaseTail = DispatchSemaphore(value: 0)
        let captured = ForwardedInput()
        let inputReceived = DispatchSemaphore(value: 0)
        try withSSHPTYAttach(requireExisting: false) { bridge in
            guard bridge.sendReady(replayBytes: 8), bridge.send("\u{1B}[cHEAD"),
                  bridge.wait(for: releaseTail), bridge.send("T") else { return }
            captured.append(bridge.receive(timeoutMilliseconds: 5_000) { $0.count >= reply.utf8.count })
            inputReceived.signal()
        } body: { attach in
            try #require(attach.output.waitForOutput(containing: "HEAD"))
            #expect(isRawForwardingMode(fd: attach.slaveFD))
            try #require(attach.write(reply))
            releaseTail.signal()
            try #require(inputReceived.wait(timeout: .now() + 6) == .success)
            #expect(captured.text == reply)
            try #require(attach.waitForExit())
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test(arguments: [SIGHUP, SIGINT, SIGTERM, SIGQUIT], [false, true])
    func terminationRestoresCallerMode(number: Int32, duringReplay: Bool) throws {
        let finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        try withSSHPTYAttach(requireExisting: duringReplay) { bridge in
            guard bridge.sendReady(replayBytes: duringReplay ? 20 : 0), bridge.send("signal-ready") else { return }
            _ = bridge.wait(for: finish)
        } body: { attach in
            try #require(attach.output.waitForOutput(containing: "signal-ready"))
            try #require(kill(attach.process.processIdentifier, number) == 0)
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 128 + number)
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test(arguments: ["{\"type\":\"error\",\"message\":\"attach rejected\"}\n", "invalid status\n", ""])
    func preReadyErrorRestoresCallerMode(status: String) throws {
        try withSSHPTYAttach(requireExisting: true) { bridge in
            _ = bridge.send(status)
        } body: { attach in
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus != 0)
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test
    func brokenOutputRestoresCallerMode() throws {
        let finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        let requests = ForwardedInput()
        try withSSHPTYAttach(requireExisting: false, outputIsBroken: true, onRequest: { method, params in
            if method == "workspace.remote.pty_attach_end" { requests.append(Data("ended".utf8)) }
            if params["acknowledge_lifecycle"] as? Bool == true { requests.append(Data("retired".utf8)) }
        }) { bridge in
            guard bridge.sendReady(replayBytes: 0), bridge.send("output-consumer-closed") else { return }
            _ = bridge.wait(for: finish)
        } body: { attach in
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 0)
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
            #expect(!requests.text.contains("retired"))
        }
    }

    @Test(arguments: [SIGHUP, SIGINT, SIGTERM, SIGQUIT])
    func signalRestoresCallerModeWithBlockedOutput(number: Int32) throws {
        try withSSHPTYAttach(requireExisting: false, outputIsBackpressured: true) { bridge in
            guard bridge.sendReady(replayBytes: 0) else { return }
            // More than the pipe and bridge buffers; the consumer stays open.
            _ = bridge.send(String(repeating: "x", count: 4 * 1024 * 1024))
        } body: { attach in
            try #require(waitUntil { isRawForwardingMode(fd: attach.slaveFD) })
            try #require(waitUntil { attach.hasBufferedOutput })
            try #require(kill(attach.process.processIdentifier, number) == 0)
            try #require(attach.waitForExit())
            #expect(attach.process.terminationStatus == 128 + number)
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
        }
    }

    @Test
    func disconnectedControlFailureDiscardsQueuedInput() throws {
        let requestSeen = DispatchSemaphore(value: 0)
        let releaseResponse = DispatchSemaphore(value: 0)
        defer { releaseResponse.signal() }
        try withSSHPTYAttach(requireExisting: true, beforeBridgeResponse: {
            requestSeen.signal()
            _ = releaseResponse.wait(timeout: .now() + 5)
        }, bridgeError: true) { _ in
            Issue.record("Control failure must not connect to the bridge")
        } body: { attach in
            try #require(requestSeen.wait(timeout: .now() + 5) == .success)
            try #require(attach.write("unwanted-local-command\n"))
            releaseResponse.signal()
            try #require(attach.waitForExit())
            #expect(TerminalFlags(fd: attach.slaveFD) == attach.initialFlags)
            _ = fcntl(attach.slaveFD, F_SETFL, O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 128)
            #expect(Darwin.read(attach.slaveFD, &buffer, buffer.count) == -1)
            #expect(errno == EAGAIN)
        }
    }
}
