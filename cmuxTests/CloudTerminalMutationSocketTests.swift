import CmuxCloudTui
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud mutation RPC ownership", .timeLimit(.minutes(1)))
struct CloudTerminalMutationSocketTests {
    private typealias Socket = CloudTuiManualIOConnectionTests

    @Test("Caller cancellation keeps the exact mutation response alive and skips queued turns",
          arguments: [false, true])
    func cancelledMutationDrainsItsOwnResponse(rejected: Bool) async throws {
        try await Socket.withResourceConnection { channel, peer in
            try await cancelledMutationScenario(channel: channel, peer: peer, rejected: rejected)
        }
    }

    @MainActor
    private func cancelledMutationScenario(
        channel: CloudTuiPersistentResourceConnection, peer: Int32, rejected: Bool
    ) async throws {
        let transport = CloudTerminalMutationSocketRunner(channel: channel)
        let commands = CloudTerminalMutationCommandRunner(base: transport) { try Task.checkCancellation() }
        let queue = CloudTerminalMutationQueue()
        var published = false
        var queuedRan = false
        var drained = false
        let active = queue.enqueue {
            let result = try await commands.runTuiCommand(arguments: mutation(), deadline: .seconds(30))
            published = true
            return result
        }
        let queued = queue.enqueue { queuedRan = true }
        defer { queue.cancelAll() }
        let original = try Socket.object(await Socket.blocking { try Socket.readLine(peer) })
        try #require(original["operation"] as? String == "workspace.run")
        #expect(original["idempotency_key"] as? String == "shielded-create")
        queue.cancelAll()
        // Task.cancel synchronously invokes registered cancellation callbacks.
        // A shielded RPC has a separate owner and therefore sees no cancellation.
        #expect(transport.cancellationCount == 0)
        let drain = Task { await queue.waitForIdle(); drained = true }

        // An unrelated reply cannot drain the cancelled mutation's turn. The
        // next wire request must be this read, with no request.cancel in front.
        try await roundTripRead(channel: channel, peer: peer)
        #expect(!drained)
        #expect(!published)
        #expect(!queuedRan)
        let reply: Data
        if rejected {
            reply = try JSONSerialization.data(withJSONObject: [
                "protocol": "cmux.protocol/2", "type": "response", "id": try #require(original["id"] as? String),
                "ok": false, "error": ["code": "revision.conflict", "message": "fixture conflict"]
            ]) + Data([10])
        } else {
            reply = try Socket.response(original, result: ["value": ["terminal_id": "term_created"]])
        }
        try await Socket.blocking { try Socket.write(peer, reply) }
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        await drain.value
        #expect(drained)
        #expect(!published && !queuedRan)
        #expect(transport.commands == ["workspace.run"])
        #expect(transport.cancellationCount == 0)
        try await roundTripRead(channel: channel, peer: peer)
    }

    @Test("Mutation response lifetime remains bounded on deadline or EOF without replay",
          arguments: ["deadline", "eof"], ["active", "cancelled", "retired"])
    func failedMutationKeepsItsDeadline(failure: String, owner: String) async throws {
        let clock = CloudCommandDeadlineClock()
        try await Socket.withResourceConnection(clock: clock) { channel, peer in
            try await failureScenario(channel: channel, peer: peer, clock: clock, failure: failure, owner: owner)
        }
    }

    @MainActor
    private func failureScenario(
        channel: CloudTuiPersistentResourceConnection, peer: Int32, clock: CloudCommandDeadlineClock,
        failure: String, owner: String
    ) async throws {
        let transport = CloudTerminalMutationSocketRunner(channel: channel)
        var current = true
        let commands = CloudTerminalMutationCommandRunner(base: transport) {
            try Task.checkCancellation()
            guard current else { throw CancellationError() }
        }
        let queue = CloudTerminalMutationQueue()
        var published = false
        let active = queue.enqueue {
            let data = try await commands.runTuiCommand(arguments: mutation(), deadline: .seconds(30))
            published = true
            return data
        }
        defer { queue.cancelAll() }
        let original = try Socket.object(await Socket.blocking { try Socket.readLine(peer) })
        try #require(original["operation"] as? String == "workspace.run")
        await clock.waitUntilSleeping()
        if owner == "cancelled" { queue.cancelAll() }
        if owner == "retired" { current = false }
        #expect(transport.cancellationCount == 0)
        if failure == "deadline" {
            clock.advance(by: .seconds(30))
        } else {
            #expect(Darwin.shutdown(peer, SHUT_RDWR) == 0)
        }
        if owner == "active" {
            await #expect(throws: CloudMachineLink.LinkError.self) { try await active.value }
        } else {
            await #expect(throws: CancellationError.self) { try await active.value }
        }
        await queue.waitForIdle()
        #expect(!published)
        #expect(transport.commands == ["workspace.run"])
        #expect(transport.cancellationCount == 0)
        if failure == "deadline" {
            // Existing deadline cleanup is advisory. It neither acknowledges a
            // mutation rollback nor replays the create under another key.
            let cancellation = try Socket.object(await Socket.blocking { try Socket.readLine(peer) })
            #expect(cancellation["operation"] as? String == "request.cancel")
            #expect((cancellation["params"] as? [String: Any])?["request_id"] as? String == original["id"] as? String)
            try await roundTripRead(channel: channel, peer: peer)
        } else {
            #expect(await channel.isClosed)
        }
    }

    @Test("Read RPCs still propagate caller cancellation to the persistent connection")
    func readsRemainCancellationResponsive() async throws {
        try await Socket.withResourceConnection { channel, peer in
            try await cancelledReadScenario(channel: channel, peer: peer)
        }
    }

    @MainActor
    private func cancelledReadScenario(channel: CloudTuiPersistentResourceConnection, peer: Int32) async throws {
        let transport = CloudTerminalMutationSocketRunner(channel: channel)
        let commands = CloudTerminalMutationCommandRunner(base: transport) { try Task.checkCancellation() }
        let queue = CloudTerminalMutationQueue()
        let active = queue.enqueue {
            try await commands.runTuiCommand(
                arguments: CloudTuiRequest("terminal.wait", ["terminal": "term_test", "pattern": "x"]),
                deadline: .seconds(30)
            )
        }
        defer { queue.cancelAll() }
        let original = try Socket.object(await Socket.blocking { try Socket.readLine(peer) })
        queue.cancelAll()
        #expect(transport.cancellationCount == 1)
        await #expect(throws: CancellationError.self) { try await active.value }
        let cancellation = try Socket.object(await Socket.blocking { try Socket.readLine(peer) })
        #expect(cancellation["operation"] as? String == "request.cancel")
        #expect((cancellation["params"] as? [String: Any])?["request_id"] as? String == original["id"] as? String)
        await queue.waitForIdle()
    }

    private func roundTripRead(channel: CloudTuiPersistentResourceConnection, peer: Int32) async throws {
        let ping = Task { try await channel.request(CloudTuiRequest("session.ping")) }
        defer { ping.cancel() }
        let request = try Socket.object(await Socket.blocking { try Socket.readLine(peer) })
        try #require(request["operation"] as? String == "session.ping")
        let response = try Socket.response(request, result: ["alive": true])
        try await Socket.blocking { try Socket.write(peer, response) }
        #expect(try Socket.object(await ping.value)["alive"] as? Bool == true)
    }

    private func mutation() -> CloudTuiRequest {
        CloudTuiRequest("workspace.run", ["workspace": "ws-source"], mutation: true, key: "shielded-create")
    }
}
