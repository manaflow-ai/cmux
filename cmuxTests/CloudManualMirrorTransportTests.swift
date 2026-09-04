import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the byte-oriented cloud terminal attachment seam.
/// The fixture speaks the same JSON lines as a cmux-tui `attach-surface` stream;
/// it never invokes the ratatui renderer or inspects source text.
@Suite
struct CloudManualMirrorTransportTests {
    private let commands = CloudTuiManualIOCommand()
    private let parser = CloudTuiLegacySnapshotParser()

    @Test
    func rawAttachFramesDeliverOutputAndResizeReplay() throws {
        let decoder = CloudTuiManualIOFrameDecoder()
        let initial = try #require(decoder.decode(try Self.line([
            "event": "vt-state",
            "surface": 17,
            "cols": 99,
            "rows": 35,
            "data": Data("initial screen".utf8).base64EncodedString(),
        ])))
        #expect(initial == .snapshot(surfaceID: 17, columns: 99, rows: 35, bytes: Data("initial screen".utf8)))

        let output = try #require(decoder.decode(try Self.line([
            "event": "output",
            "surface": 17,
            "data": Data("prompt> ".utf8).base64EncodedString(),
        ])))
        #expect(output == .output(surfaceID: 17, bytes: Data("prompt> ".utf8)))

        let resized = try #require(decoder.decode(try Self.line([
            "event": "resized",
            "surface": 17,
            "cols": 140,
            "rows": 48,
            "replay": Data("resized screen".utf8).base64EncodedString(),
        ])))
        #expect(resized == .resized(surfaceID: 17, columns: 140, rows: 48, bytes: Data("resized screen".utf8)))
    }

    @Test
    func inputAndResizeCommandsTargetTheRemotePtyWithoutRendering() throws {
        let attach = try #require(commands.attach(surfaceID: 17, columns: 120, rows: 40))
        #expect(attach["cmd"] as? String == "attach-surface")
        #expect(attach["surface"] as? UInt64 == 17)
        #expect(attach["cols"] as? Int == 120)
        #expect(attach["rows"] as? Int == 40)

        let input = commands.input(surfaceID: 17, bytes: Data("claude\r".utf8))
        #expect(input["cmd"] as? String == "send")
        #expect(input["surface"] as? UInt64 == 17)
        #expect(input["bytes"] as? String == Data("claude\r".utf8).base64EncodedString())

        let resize = commands.resize(surfaceID: 17, columns: 160, rows: 52)
        #expect(resize["cmd"] as? String == "resize-surface")
        #expect(resize["surface"] as? UInt64 == 17)
        #expect(resize["cols"] as? Int == 160)
        #expect(resize["rows"] as? Int == 52)
    }

    @Test
    func capabilityHandshakeAndLeasedResizeUseExactAttachment() throws {
        let identify = commands.identify(requestID: 4)
        #expect(identify["cmd"] as? String == "identify")
        #expect(identify["id"] as? UInt64 == 4)

        let resize = try #require(
            commands.resizeAttachedView(
                surfaceID: 17,
                lease: "lease-token",
                columns: 160,
                rows: 52,
                requestID: 8
            )
        )
        #expect(resize["cmd"] as? String == "resize-attached-view")
        #expect(resize["lease"] as? String == "lease-token")
        #expect(resize["cols"] as? Int == 160)
        #expect(resize["rows"] as? Int == 52)

        let release = try #require(
            commands.releaseAttachedViewSize(
                surfaceID: 17,
                lease: "lease-token"
            )
        )
        #expect(release["cmd"] as? String == "release-attached-view-size")
        #expect(release["lease"] as? String == "lease-token")
        #expect(
            commands.resizeAttachedView(
                surfaceID: 17,
                lease: "",
                columns: 160,
                rows: 52
            ) == nil
        )
        #expect(
            commands.resizeAttachedView(
                surfaceID: 17,
                lease: "lease-token",
                columns: 10_001,
                rows: 52
            ) == nil
        )
    }

    @Test
    func leaseCapabilityWithoutAResponseTokenFailsClosed() {
        #expect(
            CloudTuiManualMirrorSession.requiresLeaseToken(
                capabilities: ["view-attachment-lease-v1"],
                lease: nil
            )
        )
        #expect(
            CloudTuiManualMirrorSession.requiresLeaseToken(
                capabilities: ["view-attachment-lease-v1"],
                lease: ""
            )
        )
        #expect(
            !CloudTuiManualMirrorSession.requiresLeaseToken(
                capabilities: ["view-attachment-lease-v1"],
                lease: "lease-token"
            )
        )
        #expect(
            !CloudTuiManualMirrorSession.requiresLeaseToken(
                capabilities: [],
                lease: nil
            )
        )
    }

    @Test
    func responseDecoderPreservesCapabilitiesAndLeaseOutcome() throws {
        let line = try Self.line([
            "id": 7,
            "ok": true,
            "data": [
                "lease": "lease-token",
                "capabilities": ["attach-initial-size"],
                "outcome": "applied",
                "accepted": false,
            ],
        ])
        let frame = try #require(CloudTuiManualIOFrameDecoder().decode(line))
        guard case let .response(requestID, ok, lease, capabilities, outcome, accepted, error) = frame else {
            Issue.record("expected a response frame")
            return
        }
        #expect(requestID == 7)
        #expect(ok)
        #expect(lease == "lease-token")
        #expect(capabilities == ["attach-initial-size"])
        #expect(outcome == "applied")
        #expect(accepted == false)
        #expect(error == nil)
    }

    @Test
    func frameDecoderRejectsBooleanAndFractionalIdentifiers() throws {
        let decoder = CloudTuiManualIOFrameDecoder()
        let eventLines = [
            Data("{\"event\":\"output\",\"surface\":true,\"data\":\"Ynl0ZXM=\"}".utf8),
            Data("{\"event\":\"output\",\"surface\":1.0,\"data\":\"Ynl0ZXM=\"}".utf8),
            Data("{\"event\":\"output\",\"surface\":1.5,\"data\":\"Ynl0ZXM=\"}".utf8),
        ]
        for line in eventLines {
            #expect(decoder.decode(line) == nil)
        }
        let responseLines = [
            Data("{\"id\":true,\"ok\":true}".utf8),
            Data("{\"id\":1.0,\"ok\":true}".utf8),
            Data("{\"id\":1.5,\"ok\":true}".utf8),
        ]
        for line in responseLines {
            #expect(decoder.decode(line) == nil)
        }
    }

    @Test
    func resolverDistinguishesNoPlacementFromMalformedNumericValues() throws {
        #expect(
            parser.resolvedSurface(
                from: try Self.line(["surface": NSNull()])
            ) == .noPlacement
        )
        #expect(
            parser.resolvedSurface(
                from: try Self.line(["surface": true])
            ) == .malformed
        )
        #expect(
            parser.resolvedSurface(
                from: try Self.line(["surface": 1.5])
            ) == .malformed
        )
    }

    @Test
    func resizeSamplesAreLatestWinsAndResumeAfterGeometryClaim() throws {
        var scheduler = CloudTuiManualIOResizeScheduler()
        let first = try #require(CloudTuiManualIOGrid(columns: 99, rows: 35))
        let final = try #require(CloudTuiManualIOGrid(columns: 160, rows: 52))

        #expect(scheduler.sample(first, canSend: true) == first)
        #expect(scheduler.sample(final, canSend: true) == nil)
        // The first acknowledgement parks the newest sample while the
        // connection promotes itself to the terminal's geometry owner.
        #expect(scheduler.acknowledge(canSend: false) == nil)
        #expect(scheduler.resume() == final)
        #expect(scheduler.inFlight == final)
        #expect(scheduler.acknowledge(canSend: true) == nil)
        #expect(scheduler.sample(final, canSend: true) == nil)
    }

    @Test
    func staleResizeAcknowledgementCannotRetireANewerGrid() throws {
        var scheduler = CloudTuiManualIOResizeScheduler()
        let old = try #require(CloudTuiManualIOGrid(columns: 99, rows: 35))
        let current = try #require(CloudTuiManualIOGrid(columns: 160, rows: 52))
        #expect(scheduler.sample(old, canSend: true) == old)
        scheduler.resetForReconnect()
        #expect(scheduler.sample(current, canSend: true) == current)
        #expect(scheduler.acknowledge(old, canSend: true) == nil)
        #expect(scheduler.inFlight == current)
        #expect(scheduler.acknowledge(current, canSend: true) == nil)
        #expect(scheduler.lastAcknowledged == current)
    }

    @Test
    func geometryClaimCommandMakesThePaneReportAuthoritative() {
        let command = commands.claimGeometry(surfaceID: 17, requestID: 9)
        #expect(command["cmd"] as? String == "set-client-sizing")
        #expect(command["surface"] as? UInt64 == 17)
        #expect(command["enabled"] as? Bool == true)
        #expect(command["exclusive"] as? Bool == true)
        #expect(command["id"] as? UInt64 == 9)
    }

    @Test
    func hiddenMirrorsReleaseTheirSizingReport() {
        let command = commands.releaseSizing(surfaceID: 17)
        #expect(command["cmd"] as? String == "release-surface-size")
        #expect(command["surface"] as? UInt64 == 17)
        #expect(command["id"] as? UInt64 == 0)
    }

    @Test
    func legacyTreeBridgesPublicTerminalIdentityToNumericSurface() throws {
        let tree: [String: Any] = [
            "workspaces": [[
                "screens": [[
                    "panes": [[
                        "tabs": [[
                            "surface": 17,
                            "terminal_resource_id": "term_remote",
                        ]],
                    ]],
                ]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: tree)
        #expect(
            parser.surfaceID(from: data, terminalID: "term_remote") == 17
        )
    }

    /// The compatibility tree is only reachable over the raw command bridge.
    /// Sent as a leading `list-workspaces` word, the resource CLI reads it as a
    /// resource scope and answers `unknown resource scope "list-workspaces"`,
    /// which left the tree — and so every cloud terminal's surface — unresolvable.
    @Test
    func legacyWorkspaceTreeIsRequestedOverTheRawCommandBridge() throws {
        let arguments = CloudTuiCommandLine.legacyListWorkspacesArguments(socketPath: "/tmp/cmux.sock")
        #expect(arguments.prefix(5).elementsEqual(["--socket", "/tmp/cmux.sock", "--json", "raw", "command"]))
        let requestIndex = try #require(arguments.firstIndex(of: "--request-json")) + 1
        let request = try #require(
            JSONSerialization.jsonObject(with: Data(arguments[requestIndex].utf8)) as? [String: Any]
        )
        #expect(request["cmd"] as? String == "list-workspaces")
        // The bare subcommand spelling is what the CLI rejects.
        #expect(!arguments.contains { $0 == "list-workspaces" })
    }

    /// `resolve-terminal` takes a terminal *host* id (UUIDv4 hex); the app only
    /// ever holds a public `term_…` resource id, whose hex is not a UUIDv4 and
    /// which no command maps to a host id. The daemon answers
    /// `invalid_terminal_id`, and treating that as a hard failure made every
    /// cloud terminal fail with "cmux-tui did not report the new terminal"
    /// instead of falling back to the tree that can resolve it.
    @Test
    func idSpaceRejectionFallsBackToTheCompatibilityTree() {
        let daemonAnswer = """
        {"code":"raw.command_failed","details":{"error":"invalid_terminal_id","id":1,"ok":false},        "message":"invalid_terminal_id","retryable":false}
        """
        #expect(
            CmuxTuiSurfaceProvider.isExplicitUnsupportedResolverError(
                CloudMachineLink.LinkError.exited(status: 1, output: daemonAnswer)
            )
        )
        // A daemon predating the resolver keeps its own fallback signal.
        #expect(
            CmuxTuiSurfaceProvider.isExplicitUnsupportedResolverError(
                CloudMachineLink.LinkError.exited(
                    status: 1,
                    output: #"{"code":"operation.unsupported"}"#
                )
            )
        )
        // An unrelated failure must still fail closed rather than silently
        // resolving a terminal against a stale tree.
        #expect(
            !CmuxTuiSurfaceProvider.isExplicitUnsupportedResolverError(
                CloudMachineLink.LinkError.exited(
                    status: 1,
                    output: #"{"code":"internal","message":"boom"}"#
                )
            )
        )
    }

    @Test
    func legacyTreeResolverRejectsNonIntegralSurfaceValuesAndScansManyIDsOnce() throws {
        let tree: [String: Any] = [
            "workspaces": [[
                "screens": [[
                    "panes": [[
                        "tabs": [
                            ["surface": 17, "terminal_resource_id": "term_one"],
                            ["surface": 23, "terminal_resource_id": "term_two"],
                            ["surface": 1.5, "terminal_resource_id": "term_fraction"],
                            ["surface": true, "terminal_resource_id": "term_bool"],
                        ],
                    ]],
                ]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: tree)
        #expect(
            parser.surfaceIDs(
                from: try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]),
                terminalIDs: ["term_one", "term_two", "term_fraction", "term_bool"]
            ) == ["term_one": 17, "term_two": 23]
        )
    }

    @Test
    func generationAwareResolverUsesThePrivateCommandShape() throws {
        let arguments = try #require(
            CloudTuiCommandLine.resolveTerminalArguments(
                socketPath: "/tmp/cmux.sock",
                terminalID: "term_0123456789abcdef0123456789abcdef"
            )
        )
        #expect(arguments.prefix(5).elementsEqual(["--socket", "/tmp/cmux.sock", "--json", "raw", "command"]))
        let requestIndex = try #require(arguments.firstIndex(of: "--request-json")) + 1
        let request = try #require(
            JSONSerialization.jsonObject(with: Data(arguments[requestIndex].utf8)) as? [String: Any]
        )
        #expect(request["cmd"] as? String == "resolve-terminal")
        #expect(request["terminal_id"] as? String == "0123456789abcdef0123456789abcdef")
    }

    @Test
    func identifyCommandUsesTheSameRawCommandBridge() throws {
        let arguments = try #require(
            CloudTuiCommandLine.identifyArguments(socketPath: "/tmp/cmux.sock")
        )
        let requestIndex = try #require(arguments.firstIndex(of: "--request-json")) + 1
        let request = try #require(
            JSONSerialization.jsonObject(with: Data(arguments[requestIndex].utf8)) as? [String: Any]
        )
        #expect(request["cmd"] as? String == "identify")
    }

    @Test
    func identifyParserAcceptsOnlyIntegralProtocolNumbers() throws {
        let parser = CloudTuiLegacySnapshotParser()
        let response = try Self.line([
            "id": 1,
            "ok": true,
            "data": ["protocol": 12],
        ])
        #expect(parser.protocolVersion(from: response) == 12)
        #expect(
            parser.protocolVersion(
                from: Data(#"{"id":1,"ok":true,"data":{"protocol":12.0}}"#.utf8)
            ) == nil
        )
        #expect(
            parser.protocolVersion(
                from: try Self.line(["id": 1, "ok": false, "data": ["protocol": 12]])
            ) == nil
        )
        #expect(
            parser.protocolVersion(
                from: try Self.line(["ok": true, "data": ["protocol": 12]])
            ) == nil
        )
        #expect(
            parser.protocolVersion(
                from: try Self.line(["id": 2, "ok": true, "data": ["protocol": 12]])
            ) == nil
        )
        #expect(
            parser.protocolVersion(
                from: Data(#"{"id":1.0,"ok":true,"data":{"protocol":12}}"#.utf8)
            ) == nil
        )
        #expect(
            parser.protocolVersion(
                from: Data(#"{"id":1,"ok":1,"data":{"protocol":12}}"#.utf8)
            ) == nil
        )
    }

    @Test
    func resolvedTerminalResponseBridgesSurfaceHandle() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "surface": 23,
            "terminal_id": "0123456789abcdef0123456789abcdef",
        ])
        #expect(parser.resolvedSurfaceID(from: data) == 23)
    }

    /// Over a cloud link the control commands and the byte attachment ride
    /// different lanes, and the daemon side applies them in arrival order. The
    /// session therefore must not send `attach-surface` until the daemon has
    /// acknowledged the capability registration; otherwise a lease-capable
    /// daemon can answer the attach without a lease and the pane never attaches.
    @Test @MainActor
    func attachWaitsForClientInfoAcknowledgement() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_0123456789abcdef0123456789abcdef",
            remoteSurfaceID: 17,
            onNeedsReconnect: {}
        )
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath)

        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        fixture.send([
            "id": identify.id,
            "ok": true,
            "data": [
                "protocol": 12,
                "capabilities": [
                    "view-attachment-lease-v1",
                    "view-attachment-detach-v1",
                    "attach-initial-size",
                ],
            ],
        ])

        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(clientInfo.cmd == "set-client-info")
        #expect(clientInfo.capabilities.contains("view-attachment-lease-v1"))

        let premature = await fixture.nextCommand(timeout: .milliseconds(400))
        #expect(
            premature == nil,
            "sent \(premature?.cmd ?? "nothing") before set-client-info was acknowledged"
        )

        fixture.send(["id": clientInfo.id, "ok": true, "data": [:]])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        #expect(attach.surface == 17)
        // No native pane is bound, so no grid may be claimed on attach.
        #expect(!attach.hasInitialSize)

        fixture.send(["id": attach.id, "ok": true, "data": ["lease": "lease-1"]])
        #expect(await Self.waitUntil { session.phase == .attached })
    }

    /// An older daemon that rejects `set-client-info` still answers it, and the
    /// byte attachment must follow that answer instead of being abandoned.
    @Test @MainActor
    func attachFollowsARejectedClientInfoOnOlderDaemons() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_0123456789abcdef0123456789abcdef",
            remoteSurfaceID: 23,
            onNeedsReconnect: {}
        )
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath)

        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 8]])

        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(clientInfo.cmd == "set-client-info")
        fixture.send(["id": clientInfo.id, "ok": false, "error": "unknown command set-client-info"])

        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        #expect(attach.surface == 23)
        fixture.send(["id": attach.id, "ok": true, "data": [:]])
        #expect(await Self.waitUntil { session.phase == .attached })
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

/// One command a fixture read from the session, reduced to the fields the
/// handshake tests assert on.
private struct CloudManualMirrorFixtureCommand: Sendable {
    let cmd: String
    let id: UInt64
    let surface: UInt64?
    let capabilities: [String]
    let hasInitialSize: Bool

    init?(_ object: [String: Any]) {
        guard let cmd = object["cmd"] as? String else { return nil }
        self.cmd = cmd
        id = (object["id"] as? NSNumber)?.uint64Value ?? 0
        surface = (object["surface"] as? NSNumber)?.uint64Value
        capabilities = object["capabilities"] as? [String] ?? []
        hasInitialSize = object["cols"] != nil || object["rows"] != nil
    }
}

/// A minimal JSON-lines stand-in for the cmux-tui control socket behind a cloud
/// link. It records every command in arrival order and lets a test script the
/// daemon's responses, so handshake ordering is observable as behavior rather
/// than as source text.
// @unchecked Sendable: every mutable field is guarded by `lock`.
private final class CloudManualMirrorSocketFixture: @unchecked Sendable {
    let socketPath: String
    private let listenerFD: Int32
    private let lock = NSLock()
    private var clientFD: Int32 = -1
    private var received: [CloudManualMirrorFixtureCommand] = []
    private var cursor = 0

    init() throws {
        let name = "cmux-mm-" + UUID().uuidString.prefix(8).lowercased() + ".sock"
        socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        listenerFD = try Self.listen(at: socketPath)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            acceptAndRead()
        }
    }

    /// The next unread command, or nil when none arrives before `timeout`.
    func nextCommand(timeout: Duration) async -> CloudManualMirrorFixtureCommand? {
        let deadline = ContinuousClock.now + timeout
        while true {
            lock.lock()
            if cursor < received.count {
                let command = received[cursor]
                cursor += 1
                lock.unlock()
                return command
            }
            lock.unlock()
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let line = data + Data([0x0A])
        lock.lock()
        let fd = clientFD
        lock.unlock()
        guard fd >= 0 else { return }
        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    func close() {
        lock.lock()
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
        lock.unlock()
        Darwin.close(listenerFD)
        unlink(socketPath)
    }

    private func acceptAndRead() {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let fd = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenerFD, $0, &length)
            }
        }
        guard fd >= 0 else { return }
        lock.lock()
        clientFD = fd
        lock.unlock()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let command = CloudManualMirrorFixtureCommand(object) else { continue }
                lock.lock()
                received.append(command)
                lock.unlock()
            }
        }
    }

    private static func listen(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "cmux.tests", code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(code))
        }
        return fd
    }
}
