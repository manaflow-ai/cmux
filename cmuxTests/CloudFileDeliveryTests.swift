import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The file delivery protocol's pure half (`cmux vm push --secret` → `vm.file_put` →
/// the in-VM `cmux file receive`): the receiver argv, what is typed into its PTY, the
/// request checks, and how its verdict is read back. The shim's side of the same
/// contract is covered by web/tests/vm-guest-cli.test.ts.
@Suite struct CloudFileDeliveryTests {
    typealias Request = CloudFileDelivery.Request

    @Test func receiverCommandIsAbsoluteAndCarriesPathAndMode() {
        #expect(CloudFileDelivery.receiverCommand(path: ".ssh/deploy_key", mode: "600")
            == ["/usr/local/bin/cmux", "file", "receive", ".ssh/deploy_key", "--mode", "600"])
        #expect(CloudFileDelivery.receiverCommand(path: "/etc/app/token", mode: "0644").last == "0644")
    }

    @Test func wireIsWrappedBase64EndingWithTheEndMarker() throws {
        let payload = Data((0..<500).map { UInt8($0 % 251) })
        let wire = CloudFileDelivery.wire(payload)
        let text = try #require(String(data: wire, encoding: .utf8))
        #expect(text.hasSuffix("\n"))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.removeLast().isEmpty)
        #expect(lines.last == CloudFileDelivery.endMarker)
        let base64Lines = lines.dropLast()
        #expect(!base64Lines.isEmpty)
        #expect(base64Lines.allSatisfy { $0.count <= CloudEnvDelivery.base64LineWidth })
        #expect(Data(base64Encoded: base64Lines.joined()) == payload)
        // The chunker the sender uses splits anywhere; reassembly is by content, not boundary.
        let chunks = CloudEnvDelivery.chunks(wire, size: 100)
        #expect(chunks.reduce(Data(), +) == wire)
    }

    @Test func validateRejectsWhatTheReceiverWouldRefuse() {
        let bytes = Data("secret".utf8)
        #expect(throws: CloudFileDelivery.DeliveryError.emptyPath) {
            try CloudFileDelivery.validate(Request(path: "  ", mode: "600", data: bytes))
        }
        for mode in ["9", "12", "07777", "rw-", ""] {
            #expect(throws: CloudFileDelivery.DeliveryError.invalidMode(mode)) {
                try CloudFileDelivery.validate(Request(path: ".npmrc", mode: mode, data: bytes))
            }
        }
        #expect(throws: CloudFileDelivery.DeliveryError.emptyPayload) {
            try CloudFileDelivery.validate(Request(path: ".npmrc", mode: "600", data: Data()))
        }
        let oversized = Data(count: CloudFileDelivery.maxPayloadBytes + 1)
        #expect(throws: CloudFileDelivery.DeliveryError.tooLarge(oversized.count)) {
            try CloudFileDelivery.validate(Request(path: ".npmrc", mode: "600", data: oversized))
        }
        #expect(throws: Never.self) {
            try CloudFileDelivery.validate(Request(path: ".npmrc", mode: "0644", data: bytes))
        }
        #expect(CloudFileDelivery.isValidMode("600"))
        #expect(CloudFileDelivery.isValidMode("0755"))
        #expect(!CloudFileDelivery.isValidMode("800"))
    }

    @Test func outcomeParsesTheLastVerdictLine() {
        let screen = """
        CMUX-FILE-READY
        CMUX-FILE-ERR bad base64
        CMUX-FILE-READY
        CMUX-FILE-OK bytes=12 path=/root/.npmrc mode=600
        """
        #expect(CloudFileDelivery.outcome(fromScreen: screen) == .ok(bytes: 12, path: "/root/.npmrc", mode: "600"))
        #expect(CloudFileDelivery.outcome(fromScreen: "CMUX-FILE-ERR destination not writable: /etc/x") == .failed("destination not writable: /etc/x"))
        #expect(CloudFileDelivery.outcome(fromScreen: "CMUX-FILE-ERR") == .failed("unknown error"))
        #expect(CloudFileDelivery.outcome(fromScreen: "CMUX-FILE-READY\n") == nil)
        #expect(CloudFileDelivery.outcome(fromScreen: "CMUX-FILE-OK bytes=12 path=/home/cmux/key bytes=900 mode=777 mode=600") == .ok(bytes: 12, path: "/home/cmux/key bytes=900 mode=777", mode: "600"))
        #expect(CloudFileDelivery.outcome(fromScreen: "CMUX-FILE-OK bytes=12 path=/home/cmux/my project/key mode=600") == .ok(bytes: 12, path: "/home/cmux/my project/key", mode: "600"))
    }

    @Test func missingFileOutcomeNeverDisclosesReceiverScreen() {
        let secret = Data("private-key-material".utf8).base64EncodedString()
        let error = CloudFileDelivery.DeliveryError.noResult(secret)
        #expect(!error.localizedDescription.contains(secret))
    }

    @Test func requireOutcomeInsistsOnTheFullByteCount() throws {
        let ok: [String: Any] = ["matched": true, "text": "CMUX-FILE-OK bytes=12 path=/root/.npmrc mode=600\n"]
        #expect(try CloudFileDelivery.requireOutcome(ok, expectedBytes: 12) == .ok(bytes: 12, path: "/root/.npmrc", mode: "600"))
        #expect(throws: CloudFileDelivery.DeliveryError.byteCountMismatch(sent: 13, reported: 12)) {
            try CloudFileDelivery.requireOutcome(ok, expectedBytes: 13)
        }
        #expect(throws: CloudFileDelivery.DeliveryError.receiverFailed("refused")) {
            try CloudFileDelivery.requireOutcome(["value": ["matched": true, "text": "CMUX-FILE-ERR refused"]], expectedBytes: 1)
        }
        #expect(throws: CloudFileDelivery.DeliveryError.noResult("nothing yet")) {
            try CloudFileDelivery.requireOutcome(["matched": false, "text": "nothing yet"], expectedBytes: 1)
        }
    }

    @Test func requireReadyTellsAnOutdatedShimFromASlowOne() {
        #expect(throws: Never.self) {
            try CloudFileDelivery.requireReady(["matched": true, "text": "CMUX-FILE-READY"], machineID: "brave-otter")
        }
        for screen in ["cmux: unknown file command 'receive'", "error: unknown resource scope `file`"] {
            #expect(throws: CloudFileDelivery.DeliveryError.outdatedShim("brave-otter")) {
                try CloudFileDelivery.requireReady(["matched": false, "text": screen], machineID: "brave-otter")
            }
        }
        #expect(throws: CloudFileDelivery.DeliveryError.receiverNotReady("$ ")) {
            try CloudFileDelivery.requireReady(["value": ["matched": false, "text": "$ "]], machineID: "brave-otter")
        }
    }

    @MainActor @Test func receiverWorkspaceIsAlwaysOwnedAndCleaned() async throws {
        var events: [String] = []
        let outcome = try await CloudFileDelivery.withReceiverWorkspace(
            createWorkspace: { events.append("create"); return "temporary" },
            closeWorkspace: { events.append("close \($0)") },
            operation: { events.append("deliver \($0)"); return CloudFileDelivery.Outcome.ok(bytes: 1, path: nil, mode: nil) }
        )
        #expect(outcome == .ok(bytes: 1, path: nil, mode: nil))
        #expect(events == ["create", "deliver temporary", "close temporary"])
    }

    @MainActor @Test func receiverWorkspaceIsCleanedAfterFailureAndBothFailuresAreReported() async {
        var closed: [String] = []
        do {
            _ = try await CloudFileDelivery.withReceiverWorkspace(
                createWorkspace: { "temporary" },
                closeWorkspace: { closed.append($0) },
                operation: { _ -> CloudFileDelivery.Outcome in throw CloudFileDelivery.DeliveryError.receiverFailed("refused") }
            )
            Issue.record("delivery should fail")
        } catch {
            #expect((error as? CloudFileDelivery.DeliveryError) == .receiverFailed("refused"))
        }
        #expect(closed == ["temporary"])

        do {
            _ = try await CloudFileDelivery.withReceiverWorkspace(
                createWorkspace: { "temporary" },
                closeWorkspace: { _ in throw CancellationError() },
                operation: { _ -> CloudFileDelivery.Outcome in throw CloudFileDelivery.DeliveryError.receiverFailed("refused") }
            )
            Issue.record("cleanup failure must not report success")
        } catch let combined as CloudFileDelivery.OperationAndCleanupError {
            #expect((combined.operationError as? CloudFileDelivery.DeliveryError) == .receiverFailed("refused"))
            #expect(combined.cleanupError == .workspaceCleanupFailed("temporary"))
            #expect(combined.localizedDescription.contains("refused"))
            #expect(combined.localizedDescription.contains("temporary"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
