import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The env delivery protocol's pure half: what is typed into `cmux env receive`, how it
/// is chunked, and how the receiver's verdict is read back. The shim's side of the same
/// contract is covered by web/tests/vm-guest-cli.test.ts.
@Suite struct CloudEnvDeliveryTests {
    typealias Entry = CloudEnvDelivery.Entry

    @MainActor @Test
    func receiverWorkspaceIsAlwaysOwnedAndCleaned() async throws {
        var events: [String] = []
        let outcome = try await CloudEnvDelivery.withReceiverWorkspace(
            createWorkspace: { events.append("create"); return "temporary" },
            closeWorkspace: { events.append("close \($0)") },
            operation: { events.append("deliver \($0)"); return .ok(keys: 1, path: nil) }
        )
        #expect(outcome == .ok(keys: 1, path: nil))
        #expect(events == ["create", "deliver temporary", "close temporary"])
    }

    @MainActor @Test(arguments: [false, true])
    func receiverWorkspaceIsCleanedAfterFailureOrCancellation(cancelled: Bool) async throws {
        var closed: [String] = []
        let task = Task { @MainActor in
            try await CloudEnvDelivery.withReceiverWorkspace(
                createWorkspace: { "temporary" },
                closeWorkspace: { workspaceID in
                    #expect(!Task.isCancelled)
                    closed.append(workspaceID)
                },
                operation: { _ in
                    if cancelled { withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() }
                    throw CloudEnvDelivery.DeliveryError.receiverFailed("refused")
                }
            )
        }
        do {
            _ = try await task.value
            Issue.record("delivery should fail")
        } catch {
            #expect(cancelled ? error is CancellationError : (error as? CloudEnvDelivery.DeliveryError) == .receiverFailed("refused"))
        }
        #expect(closed == ["temporary"])
    }

    @MainActor @Test func receiverWorkspaceCleanupFailureIsReported() async {
        do {
            _ = try await CloudEnvDelivery.withReceiverWorkspace(
                createWorkspace: { "temporary" },
                closeWorkspace: { _ in throw CancellationError() },
                operation: { _ in .ok(keys: 1, path: nil) }
            )
            Issue.record("cleanup failure must not report success")
        } catch {
            #expect(error as? CloudEnvDelivery.DeliveryError == .workspaceCleanupFailed("temporary"))
        }
    }

    @Test func temporaryReceiverWorkspaceDoesNotStartAnExtraShell() {
        #expect(CloudTuiCommandLine.createWorkspaceArguments(socketPath: "/tmp/test.sock", name: "receiver", empty: true)
            == ["--socket", "/tmp/test.sock", "--json", "workspace", "create", "--name", "receiver", "--empty"])
    }

    @MainActor @Test(arguments: [false, true])
    func receiverTerminalsMustCloseBeforeTheirWorkspace(fail: Bool) async {
        var events: [String] = []
        do {
            try await CloudEnvDelivery.removeReceiverResources(
                terminalIDs: ["receiver"],
                closeTerminal: {
                    events.append("terminal \($0)")
                    if fail { throw CloudEnvDelivery.DeliveryError.receiverFailed("close failed") }
                },
                closeWorkspace: { events.append("workspace") }
            )
            #expect(!fail)
        } catch {
            #expect(fail)
        }
        #expect(events == (fail ? ["terminal receiver"] : ["terminal receiver", "workspace"]))
    }

    @MainActor @Test(arguments: [false, true])
    func receiverCleanupUsesKnownReceiptWithoutCatalogRefresh(refreshWouldFail: Bool) async throws {
        var events: [String] = []
        try await CloudEnvDelivery.removeReceiverResources(
            terminalIDs: ["owned-receiver"],
            discoverTerminalIDs: {
                events.append("refresh")
                if refreshWouldFail { throw CancellationError() }
                return []
            },
            closeTerminal: { events.append("terminal \($0)") },
            closeWorkspace: { events.append("workspace") }
        )
        #expect(events == ["terminal owned-receiver", "workspace"])
    }

    @MainActor @Test(arguments: [false, true])
    func receiverCleanupWithoutReceiptRequiresAuthoritativeDiscovery(refreshFails: Bool) async {
        var events: [String] = []
        do {
            try await CloudEnvDelivery.removeReceiverResources(
                terminalIDs: [],
                discoverTerminalIDs: {
                    events.append("refresh")
                    if refreshFails { throw CancellationError() }
                    return ["discovered-receiver"]
                },
                closeTerminal: { events.append("terminal \($0)") },
                closeWorkspace: { events.append("workspace") }
            )
            #expect(!refreshFails)
        } catch {
            #expect(refreshFails)
        }
        #expect(events == (refreshFails ? ["refresh"] : ["refresh", "terminal discovered-receiver", "workspace"]))
    }

    @MainActor @Test(arguments: [
        CloudEnvDelivery.DeliveryError.receiverFailed("refused-marker"),
        .outdatedShim("machine-marker"),
        .receiverNotReady("not-ready-marker")
    ])
    func deliveryAndCleanupFailuresAreBothReported(primaryError: CloudEnvDelivery.DeliveryError) async {
        var closed: [String] = []
        do {
            _ = try await CloudEnvDelivery.withReceiverWorkspace(
                createWorkspace: { "temporary-marker" },
                closeWorkspace: { workspaceID in
                    closed.append(workspaceID)
                    throw CancellationError()
                },
                operation: { _ in throw primaryError }
            )
            Issue.record("both failures must be reported")
        } catch {
            #expect(error.localizedDescription.contains(primaryError.localizedDescription))
            #expect(error.localizedDescription.contains("temporary-marker"))
        }
        #expect(closed == ["temporary-marker"])
    }

    @MainActor @Test(arguments: [false, true])
    func combinedCleanupFailurePreservesCancellationAndRedactsUnknownErrors(cancelled: Bool) async throws {
        let failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-sdk-sentinel"])
        do {
            _ = try await CloudEnvDelivery.withReceiverWorkspace(
                createWorkspace: { "temporary-marker" },
                closeWorkspace: { _ in throw failure },
                operation: { _ in
                    if cancelled { throw CancellationError() }
                    throw failure
                }
            )
            Issue.record("both failures must be reported")
        } catch {
            let combined = try #require(error as? CloudEnvDelivery.OperationAndCleanupError)
            #expect(combined.cleanupError == .workspaceCleanupFailed("temporary-marker"))
            #expect(cancelled ? combined.operationError is CancellationError : (combined.operationError as NSError) == failure)
            #expect(!combined.localizedDescription.contains("private-sdk-sentinel"))
            #expect(combined.localizedDescription.contains("temporary-marker"))
        }
    }

    @Test func payloadIsLiteralKeyValueLines() throws {
        let payload = try CloudEnvDelivery.payload([
            Entry(key: "A", value: "1"),
            Entry(key: "SPACEY", value: "  padded  "),
            Entry(key: "QUOTED", value: "'x' \"y\""),
            Entry(key: "EMPTY", value: ""),
        ])
        #expect(String(decoding: payload, as: UTF8.self) == "A=1\nSPACEY=  padded  \nQUOTED='x' \"y\"\nEMPTY=\n")
    }

    @Test func payloadRejectsBadKeysMultilineValuesAndNothing() {
        #expect(throws: CloudEnvDelivery.DeliveryError.invalidKey("1BAD")) {
            try CloudEnvDelivery.payload([Entry(key: "1BAD", value: "v")])
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.invalidKey("A-B")) {
            try CloudEnvDelivery.payload([Entry(key: "A-B", value: "v")])
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.multilineValue("A")) {
            try CloudEnvDelivery.payload([Entry(key: "A", value: "one\ntwo")])
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.emptyPayload) {
            try CloudEnvDelivery.payload([])
        }
    }

    @Test func payloadSizeIsCapped() {
        let huge = String(repeating: "x", count: CloudEnvDelivery.maxPayloadBytes)
        #expect(throws: CloudEnvDelivery.DeliveryError.self) {
            try CloudEnvDelivery.payload([Entry(key: "BIG", value: huge)])
        }
    }

    @Test func wireIsWrappedBase64FollowedByTheEndMarker() throws {
        let payload = try CloudEnvDelivery.payload([Entry(key: "TOKEN", value: String(repeating: "s", count: 200))])
        let wire = String(decoding: CloudEnvDelivery.wire(payload), as: UTF8.self)
        let lines = wire.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Trailing newline, then the marker as the last real line.
        #expect(lines.last == "")
        #expect(lines.dropLast().last == CloudEnvDelivery.endMarker)
        let base64Lines = lines.dropLast(2)
        #expect(!base64Lines.isEmpty)
        #expect(base64Lines.allSatisfy { $0.count <= CloudEnvDelivery.base64LineWidth })
        #expect(base64Lines.dropLast().allSatisfy { $0.count == CloudEnvDelivery.base64LineWidth })
        // Every value never appears in the clear on the wire, and the wire decodes back.
        #expect(!wire.contains("TOKEN="))
        let decoded = Data(base64Encoded: base64Lines.joined())
        #expect(decoded == payload)
    }

    @Test func chunksCoverTheWireExactlyAtAnyCut() throws {
        let wire = CloudEnvDelivery.wire(try CloudEnvDelivery.payload([Entry(key: "K", value: String(repeating: "v", count: 3_000))]))
        let chunks = CloudEnvDelivery.chunks(wire, size: 700)
        #expect(chunks.count == Int((Double(wire.count) / 700).rounded(.up)))
        #expect(chunks.dropLast().allSatisfy { $0.count == 700 })
        #expect(chunks.reduce(Data(), +) == wire)
        #expect(CloudEnvDelivery.chunks(Data(), size: 10).isEmpty)
        #expect(CloudEnvDelivery.chunks(wire, size: 0) == [wire])
    }

    @Test func outcomeReadsTheReceiversVerdictLastLineWins() {
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-READY\nCMUX-ENV-OK keys=3 path=/root/.config/cmux/env\n") == .ok(keys: 3, path: "/root/.config/cmux/env"))
        #expect(CloudEnvDelivery.outcome(fromScreen: "junk\r\nCMUX-ENV-ERR invalid-key 1BAD\n") == .failed("invalid-key 1BAD"))
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-ERR timeout\nCMUX-ENV-OK keys=1\n") == .ok(keys: 1, path: nil))
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-ERR") == .failed("unknown error"))
        #expect(CloudEnvDelivery.outcome(fromScreen: "CMUX-ENV-READY\n$ ") == nil)
    }

    @Test(arguments: [false, true])
    func receiverPhasesAcceptDaemonReplies(wrapped: Bool) throws {
        let ready: [String: Any] = ["matched": true, "text": "CMUX-ENV-READY\n"]
        let result: [String: Any] = ["matched": true, "text": "CMUX-ENV-OK keys=2 path=/root/.config/cmux/env\n"]
        try CloudEnvDelivery.requireReady(wrapped ? ["value": ready] : ready, machineID: "test-machine")
        #expect(try CloudEnvDelivery.requireOutcome(wrapped ? ["value": result] : result) == .ok(keys: 2, path: "/root/.config/cmux/env"))
    }

    @Test func wrappedReceiverFailuresKeepTheirDiagnostics() {
        #expect(throws: CloudEnvDelivery.DeliveryError.outdatedShim("test-machine")) {
            try CloudEnvDelivery.requireReady(["value": ["matched": false, "text": "unknown resource scope env"]], machineID: "test-machine")
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.receiverNotReady("still starting")) {
            try CloudEnvDelivery.requireReady(["value": ["matched": false, "text": "still starting"]], machineID: "test-machine")
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.receiverFailed("invalid-key 1BAD")) {
            try CloudEnvDelivery.requireOutcome(["value": ["matched": true, "text": "CMUX-ENV-ERR invalid-key 1BAD\n"]])
        }
        #expect(throws: CloudEnvDelivery.DeliveryError.noResult("CMUX-ENV-READY")) {
            try CloudEnvDelivery.requireOutcome(["value": ["matched": false, "text": "CMUX-ENV-READY"]])
        }
    }

    @Test func outdatedShimIsRecognizedFromTheScreen() {
        #expect(CloudEnvDelivery.looksLikeOutdatedShim("error: unknown resource scope \"env\"\n"))
        #expect(CloudEnvDelivery.looksLikeOutdatedShim("cmux: unknown env command 'receive'"))
        #expect(!CloudEnvDelivery.looksLikeOutdatedShim("CMUX-ENV-READY"))
    }

    @Test func senderArgvKeepsTheReceiverScreenAndWritesRawBytes() {
        // The receiver's verdict is its last screen line: the run must keep the tab
        // after exit, and the payload rides `--bytes-base64`, never `--text`/argv text.
        #expect(
            CloudTuiCommandLine.runArguments(socketPath: "/tmp/l.sock", workspaceID: "ws_1", command: CloudEnvDelivery.receiverCommand, onExit: "keep")
                == ["--socket", "/tmp/l.sock", "--json", "workspace", "ws_1", "run", "--on-exit", "keep", "--", "/usr/local/bin/cmux", "env", "receive"]
        )
        #expect(
            CloudTuiCommandLine.runArguments(socketPath: "/tmp/l.sock", workspaceID: "ws_1", command: ["bash", "-l"])
                == ["--socket", "/tmp/l.sock", "--json", "workspace", "ws_1", "run", "--", "bash", "-l"]
        )
        #expect(
            CloudTuiCommandLine.writeBytesArguments(socketPath: "/tmp/l.sock", terminalID: "term_1")
                == ["--socket", "/tmp/l.sock", "--json", "terminal", "term_1", "write"]
        )
    }

    @Test func receiverIsStartedByAbsolutePathWithNoValueInArgv() {
        #expect(CloudEnvDelivery.receiverCommand == ["/usr/local/bin/cmux", "env", "receive"])
        #expect(CloudEnvDelivery.readyTimeoutMs < CloudEnvDelivery.resultTimeoutMs)
        #expect(CloudEnvDelivery.chunkBytes < 4_096, "a canonical-mode PTY line holds at most 4095 bytes")
    }
}
