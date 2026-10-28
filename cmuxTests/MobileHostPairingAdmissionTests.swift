import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension MobileHostAuthorizationTests {
    @Test func pendingTailscalePoolCannotConsumeAuthenticatedConnectionCapacity() throws {
        let registry = MobileHostConnectionRegistry()
        defer { _ = registry.removeAll() }
        let pendingIDs = [UUID(), UUID()]
        for id in pendingIDs {
            #expect(registry.insert(
                pairingAdmissionSession(id: id), id: id, authorization: .stackBearer,
                limit: 2, pendingAuthentication: true
            ))
        }
        let excessPendingID = UUID()
        #expect(!registry.insert(
            pairingAdmissionSession(id: excessPendingID), id: excessPendingID,
            authorization: .stackBearer, limit: 2, pendingAuthentication: true
        ))

        let authenticatedID = UUID()
        let irohID = UUID()
        #expect(registry.insert(
            pairingAdmissionSession(id: authenticatedID), id: authenticatedID,
            authorization: .stackBearer, limit: 2
        ))
        #expect(registry.insert(
            pairingAdmissionSession(id: irohID), id: irohID,
            authorization: try irohAdmissionContext(), limit: 2
        ))
        let excessAuthenticatedID = UUID()
        #expect(!registry.insert(
            pairingAdmissionSession(id: excessAuthenticatedID), id: excessAuthenticatedID,
            authorization: .stackBearer, limit: 2
        ))
        #expect(registry.count == 4)
        #expect(registry.usableConnectionCount == 0)
    }

    @Test func tailscalePromotionHonorsAuthenticatedCapacityAndReleasesPendingCapacity() throws {
        let registry = MobileHostConnectionRegistry()
        defer { _ = registry.removeAll() }
        let irohID = UUID()
        let pendingID = UUID()
        try #require(registry.insert(
            pairingAdmissionSession(id: irohID), id: irohID,
            authorization: try irohAdmissionContext(), limit: 1
        ))
        try #require(registry.insert(
            pairingAdmissionSession(id: pendingID), id: pendingID,
            authorization: .stackBearer, limit: 1, pendingAuthentication: true
        ))

        #expect(!registry.promoteStackBearerConnection(id: pendingID, limit: 1))
        #expect(!registry.markUsable(id: pendingID))
        #expect(!registry.promoteStackBearerConnection(id: irohID, limit: 1))
        #expect(!registry.promoteStackBearerConnection(id: UUID(), limit: 1))

        registry.remove(id: irohID)
        try #require(registry.promoteStackBearerConnection(id: pendingID, limit: 1))
        #expect(registry.promoteStackBearerConnection(id: pendingID, limit: 1))
        let nextPendingID = UUID()
        #expect(registry.insert(
            pairingAdmissionSession(id: nextPendingID), id: nextPendingID,
            authorization: .stackBearer, limit: 1, pendingAuthentication: true
        ))
        #expect(!registry.promoteStackBearerConnection(id: nextPendingID, limit: 1))
        #expect(registry.count == 2)
        #expect(registry.usableConnectionCount == 0)
    }

    @Test func pairingCountRequiresAnEstablishedSessionAndDropsRemovedSessions() throws {
        let registry = MobileHostConnectionRegistry()
        defer { _ = registry.removeAll() }
        let pendingID = UUID()
        let authenticatedID = UUID()
        let irohID = UUID()
        try #require(registry.insert(
            pairingAdmissionSession(id: pendingID), id: pendingID,
            authorization: .stackBearer, limit: 2, pendingAuthentication: true
        ))
        try #require(registry.insert(
            pairingAdmissionSession(id: authenticatedID), id: authenticatedID,
            authorization: .stackBearer, limit: 2
        ))
        try #require(registry.insert(
            pairingAdmissionSession(id: irohID), id: irohID,
            authorization: try irohAdmissionContext(), limit: 2
        ))
        #expect(registry.usableConnectionCount == 0)
        #expect(!registry.markUsable(id: pendingID))
        #expect(!registry.markUsable(id: UUID()))
        #expect(registry.markUsable(id: authenticatedID))
        #expect(registry.markUsable(id: authenticatedID))
        #expect(registry.usableConnectionCount == 1)
        #expect(registry.markUsable(id: irohID))
        #expect(registry.usableConnectionCount == 2)

        registry.remove(id: authenticatedID)
        #expect(registry.usableConnectionCount == 1)
        #expect(!registry.markUsable(id: authenticatedID))
        _ = registry.removeAllIrohConnections()
        #expect(registry.usableConnectionCount == 0)
        #expect(registry.count == 1)
    }

    @Test("Public status and denied requests cannot extend TCP admission", .timeLimit(.minutes(1)),
          arguments: ["mobile.host.status", "workspace.list"])
    func unauthenticatedRequestsDoNotDefeatAdmissionDeadline(method: String) async throws {
        let clock = SidebarTestManualClock()
        let transport = ScriptedMobileHostByteTransport()
        let frames = try ["first", "second"].map {
            try Self.pairingAdmissionRequestFrame(id: $0, method: method)
        }
        let session = MobileHostConnection(
            id: UUID(), transport: transport,
            firstFrameTimeoutNanoseconds: 15_000_000_000,
            firstFrameClock: clock, requiresAuthenticatedRequest: true,
            authorizeRequest: { request in
                request.method == "mobile.host.status" ? nil : .failure(
                    MobileHostRPCError(code: "unauthorized", message: "Fixture denied the request")
                )
            },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok(["reachable": true]) },
            onClose: { _ in }
        )
        let runTask = Task { await session.run() }
        do {
            await clock.waitUntilSleeping(for: .seconds(15))
            for (index, frame) in frames.enumerated() {
                clock.advance(by: .seconds(7))
                await transport.enqueue(frame)
                let sent = await transport.waitForSentBufferCount(index + 1)
                let response = try Self.pairingAdmissionResponse(try #require(sent.last))
                #expect(response["ok"] as? Bool == (method == "mobile.host.status"))
                if method != "mobile.host.status" {
                    #expect((response["error"] as? [String: Any])?["code"] as? String == "unauthorized")
                }
                try #require(clock.sleeperCount == 1, "An unauthenticated frame must not cancel admission expiry")
            }
            clock.advance(by: .seconds(1))
            try #require(clock.sleeperCount == 0, "Requests must not move the original admission deadline")
            await transport.waitForCloseCount(1)
            #expect(await runTask.value == CmxIrohAdmittedConnectionExit(
                lifecycle: .controlReadFailed, failure: .timedOut
            ))
            #expect(await transport.observedCloseCount() == 1)
        } catch {
            await session.close(reason: "admission regression failed")
            _ = await runTask.value
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulProtectedRequestKeepsTCPUsablePastAdmissionDeadline() async throws {
        let clock = SidebarTestManualClock()
        let transport = ScriptedMobileHostByteTransport()
        let initial = try Self.pairingAdmissionRequestFrame(
            id: "authenticate", method: "workspace.list", stackAccessToken: "fixture-owner"
        )
        let later = try Self.pairingAdmissionRequestFrame(
            id: "after-deadline", method: "workspace.list", stackAccessToken: "fixture-owner"
        )
        let session = MobileHostConnection(
            id: UUID(), transport: transport,
            firstFrameTimeoutNanoseconds: 15_000_000_000,
            firstFrameClock: clock, requiresAuthenticatedRequest: true,
            authorizeRequest: { request in
                request.auth?.stackAccessToken == "fixture-owner" ? nil : .failure(
                    MobileHostRPCError(code: "unauthorized", message: "Fixture denied the request")
                )
            },
            onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok(["workspaces": [["id": "workspace-a"]]]) },
            onClose: { _ in }
        )
        let runTask = Task { await session.run() }
        do {
            await clock.waitUntilSleeping(for: .seconds(15))
            clock.advance(by: .seconds(14))
            await transport.enqueue(initial)
            let first = await transport.waitForSentBufferCount(1)
            let initialResponse = try Self.pairingAdmissionResponse(try #require(first.last))
            #expect(initialResponse["ok"] as? Bool == true)
            try #require(clock.sleeperCount == 0, "A credential-checked request must end admission expiry")

            clock.advance(by: .seconds(2))
            await transport.enqueue(later)
            let sent = await transport.waitForSentBufferCount(2)
            let laterResponse = try Self.pairingAdmissionResponse(try #require(sent.last))
            #expect(laterResponse["id"] as? String == "after-deadline")
            #expect(laterResponse["ok"] as? Bool == true)
            #expect(await transport.observedCloseCount() == 0)
        } catch {
            await session.close(reason: "authenticated admission regression failed")
            _ = await runTask.value
            throw error
        }
        await session.close(reason: "admission regression complete")
        _ = await runTask.value
    }

    private func pairingAdmissionSession(id: UUID) -> MobileHostConnection {
        MobileHostConnection(
            id: id, transport: RecordingMobileHostByteTransport(),
            authorizeRequest: { _ in nil }, onAuthorizedRequest: { _ in },
            handleRequest: { _ in .ok([:]) }, onClose: { _ in }
        )
    }

    private static func pairingAdmissionRequestFrame(
        id: String, method: String, stackAccessToken: String? = nil
    ) throws -> Data {
        var request: [String: Any] = ["id": id, "method": method, "params": [String: Any]()]
        if let stackAccessToken {
            request["auth"] = ["stack_access_token": stackAccessToken]
        }
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: request))
    }

    private static func pairingAdmissionResponse(_ data: Data) throws -> [String: Any] {
        var buffer = data
        let frame = try #require(MobileSyncFrameCodec.decodeFrames(from: &buffer).first)
        return try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
    }
}
