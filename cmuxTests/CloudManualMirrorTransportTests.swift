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
    }

    @Test
    func resolvedTerminalResponseBridgesSurfaceHandle() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "surface": 23,
            "terminal_id": "0123456789abcdef0123456789abcdef",
        ])
        #expect(parser.resolvedSurfaceID(from: data) == 23)
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
