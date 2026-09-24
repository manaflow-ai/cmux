import CmuxCloudTui
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(CloudCommandFixture)
@testable import CloudCommandFixture
#endif

@Suite(.timeLimit(.minutes(1))) struct CloudCommandDeadlineTests {
    private typealias Socket = CloudTuiManualIOConnectionTests

    @Test(arguments: [false, true])
    func responseAfterDeadlineFailsEvenWhenTimerHasNotResumed(raw: Bool) async throws {
        let clock = CloudCommandDeadlineClock()
        try await Socket.withResourceConnection(clock: clock) { channel, peer in
            let command = Task { try await channel.request(CloudTuiRequest("session.ping", raw: raw), timeout: .seconds(30)) }
            defer { command.cancel() }
            let bytes = try await Socket.blocking { try Socket.readLine(peer) }
            let request = try Socket.object(bytes)
            let requestID = try #require(request["id"] as? String)
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(600), wakingTimers: false)
            try Socket.write(peer, Socket.response(request, result: ["expired": true], raw: raw))
            do {
                _ = try await command.value
                Issue.record("a response delivered after resume cannot turn an expired request into success")
            } catch CloudMachineLink.LinkError.timedOut {}

            // An expired request never closes the machine-owned socket or replays work.
            async let sibling = channel.request(CloudTuiRequest("session.snapshot"))
            try await Socket.blocking {
                var next = try Socket.object(Socket.readLine(peer))
                if next["operation"] as? String == "request.cancel" {
                    #expect(!raw)
                    #expect((next["params"] as? [String: Any])?["request_id"] as? String == requestID)
                    next = try Socket.object(Socket.readLine(peer))
                }
                #expect(next["operation"] as? String == "session.snapshot")
                try Socket.write(peer, Socket.response(next, result: ["alive": true]))
            }
            let siblingResult = try await sibling
            #expect(try Socket.object(siblingResult)["alive"] as? Bool == true)
            #expect(!(await channel.isClosed))
        }
    }

    @Test(arguments: [false, true])
    func responseBeforeDeadlinePreservesOutput(raw: Bool) async throws {
        let clock = CloudCommandDeadlineClock()
        try await Socket.withResourceConnection(clock: clock) { channel, peer in
            async let command = channel.request(CloudTuiRequest("session.ping", raw: raw), timeout: .seconds(30))
            let bytes = try await Socket.blocking { try Socket.readLine(peer) }
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(29), wakingTimers: false)
            try Socket.write(peer, Socket.response(Socket.object(bytes), result: ["value": "unchanged"], raw: raw))
            let commandResult = try await command
            #expect(try Socket.object(commandResult)["value"] as? String == "unchanged")
        }
    }

    @Test(arguments: [Duration.zero, .seconds(-1)])
    func expiredBudgetIsRejectedBeforeOpeningSocket(timeout: Duration) async throws {
        let channel = CloudTuiPersistentResourceConnection(socketPath: "/does/not/exist")
        do {
            _ = try await channel.request(CloudTuiRequest("session.ping"), timeout: timeout)
            Issue.record("an expired request must be rejected")
        } catch CloudMachineLink.LinkError.timedOut {}
        await channel.close()
    }
}
