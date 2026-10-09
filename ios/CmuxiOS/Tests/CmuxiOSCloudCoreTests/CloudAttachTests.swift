import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation
import Testing

struct CloudAttachTests {
    private let host = HostID("host_h0000000000000000001")

    private func connectInfo(
        state: String = "running",
        services: [String] = ["daemon", "ssh"],
        key: String? = nil,
        host: String = "host_h0000000000000000001",
        machine: String = "vm_m0000000000000000001",
        epoch: Int = 7
    ) -> JSONValue {
        let wireKey = key ?? Data(repeating: 0, count: 32).base64EncodedString()
        return .object([
            "machine": .string(machine), "host": .string(host), "epoch": .int(Int64(epoch)),
            "state": .string(state),
            "peer": .object([
                "wg_public_key": .string(wireKey), "overlay_address": .string("fd7c:6d78::1"),
                "vpc_endpoint": .null, "public_ipv6": .null
            ]),
            "gateway": .null,
            "services": .array(services.map(JSONValue.string)),
            "daemon": .object(["version": .string("0.1"), "capabilities": .array([])]),
            "revision": .string("8")
        ])
    }

    @Test func decodesConnectInfoWithoutASecret() throws {
        let info = try CloudWireDecoder().connectInfo(connectInfo())
        #expect(info.machineID == "vm_m0000000000000000001")
        #expect(info.hostID == host)
        #expect(info.epoch == 7)
        #expect(info.services == [.daemon, .ssh])
        #expect(info.peer.wireGuardPublicKey == Data(repeating: 0, count: 32).base64EncodedString())
    }

    @Test func plannerReturnsResumeForPausedAndReadyForRunning() throws {
        let decoder = CloudWireDecoder()
        let paused = try decoder.connectInfo(connectInfo(state: "paused"))
        #expect(try CloudAttachPlanner.plan(info: paused, service: .daemon) == .resumeRequired(.paused))

        let running = try decoder.connectInfo(connectInfo())
        let machine = CloudMachine(id: running.machineID, status: .running, host: host)
        let decision = try CloudAttachPlanner.plan(info: running, service: .daemon, expectedMachine: machine, expectedHost: host)
        guard case .ready(let plan) = decision else {
            Issue.record("running machine must produce a ready attach plan")
            return
        }
        #expect(plan.service == .daemon)
        #expect(plan.info.hostID == host)
    }

    @Test func plannerRejectsMismatchedIdentityAndMalformedPeer() throws {
        let decoder = CloudWireDecoder()
        let info = try decoder.connectInfo(connectInfo())
        let wrongMachine = CloudMachine(id: "vm_m0000000000000000002", status: .running, host: host)
        #expect(throws: CloudAttachValidationError.machineMismatch) {
            try CloudAttachPlanner.plan(info: info, service: .daemon, expectedMachine: wrongMachine)
        }
        let malformed = try decoder.connectInfo(connectInfo(key: "bad"))
        #expect(throws: CloudAttachValidationError.invalidPeer) {
            try CloudAttachPlanner.plan(info: malformed, service: .daemon)
        }
    }

    @Test func decoderRejectsUnknownAndDuplicateServices() {
        let decoder = CloudWireDecoder()
        #expect(throws: CloudWireDecodeError.unknownService("files")) {
            try decoder.connectInfo(connectInfo(services: ["files"]))
        }
        #expect(throws: CloudWireDecodeError.invalidServices) {
            try decoder.connectInfo(connectInfo(services: ["daemon", "daemon"]))
        }
    }

    @Test func preflightUsesExactlyOneSelectorAndTheInstallRead() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        let preflight = CloudAttachPreflight(api: api)
        let result = try await preflight.resolve(hostID: host, service: .daemon)
        guard case .ready = result else {
            Issue.record("running connect-info should be ready")
            return
        }
        let call = try #require(await api.calls.last)
        #expect(call.op == "cloud.machine.connect_info")
        #expect(call.params == ["host": .string(host.rawValue)])

        await #expect(throws: CloudAPIError.refused(code: "validation.invalid")) {
            try await preflight.resolve(machineID: "vm_m0000000000000000001", hostID: host, service: .daemon)
        }
    }

    @Test func attachSessionMintsAOneShotDaemonGrantAndUsesInstallPrincipal() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.set(replies: [.committed(value: CloudJSON.linkToken(), revision: 0)])
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        guard case .ready = try await session.prepare(hostID: host, service: .daemon) else {
            Issue.record("running machine should be attachable")
            return
        }

        let grant = try await session.mintHelloToken()
        #expect(grant.token == "secret")
        #expect(grant.hostID == host)
        #expect(grant.epoch == 7)
        #expect(grant.services == [.daemon])
        let call = try #require(await api.calls.last)
        #expect(call.op == "cloud.machine.link_token")
        #expect(call.key == "")
        #expect(call.principal == .install)
        #expect(call.params == ["host": .string(host.rawValue), "services": .array([.string("daemon")])])

        await #expect(throws: CloudAttachSessionError.credentialAlreadyIssued) {
            _ = try await session.mintHelloToken()
        }
    }

    @Test func reconnectRequiresFreshConnectInfoAndToken() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.set(replies: [
            .committed(value: CloudJSON.linkToken(token: "first"), revision: 0),
            .committed(value: CloudJSON.linkToken(token: "second"), revision: 0),
        ])
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await session.prepare(hostID: host, service: .daemon)
        #expect(try await session.mintHelloToken().token == "first")
        await session.resetForReconnect()
        await #expect(throws: CloudAttachSessionError.notPrepared) {
            _ = try await session.mintHelloToken()
        }
        _ = try await session.prepare(hostID: host, service: .daemon)
        #expect(try await session.mintHelloToken().token == "second")
        #expect(await api.count("cloud.machine.connect_info") == 2)
        #expect(await api.count("cloud.machine.link_token") == 2)
    }

    @Test func attachSessionRejectsGrantForAnotherEpochOrHost() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.set(replies: [.committed(value: CloudJSON.linkToken(host: "host_other", epoch: 8), revision: 0)])
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await session.prepare(hostID: host, service: .daemon)
        await #expect(throws: CloudAttachSessionError.invalidGrant) {
            _ = try await session.mintHelloToken()
        }
    }

    @Test func attachSessionRejectsAGrantWithExtraServices() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.set(replies: [.committed(value: CloudJSON.linkToken(services: ["daemon", "ssh"]), revision: 0)])
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await session.prepare(hostID: host, service: .daemon)
        await #expect(throws: CloudAttachSessionError.invalidGrant) {
            _ = try await session.mintHelloToken()
        }
    }

    @Test func attachSessionRequiresReconnectResetAfterIssuingGrant() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.set(replies: [.committed(value: CloudJSON.linkToken(), revision: 0)])
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await session.prepare(hostID: host, service: .daemon)
        _ = try await session.mintHelloToken()
        await #expect(throws: CloudAttachSessionError.credentialAlreadyIssued) {
            _ = try await session.prepare(hostID: host, service: .ssh)
        }
        #expect(await api.count("cloud.machine.connect_info") == 1)
    }

    @Test func concurrentMintsReserveTheSingleHelloGrant() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.set(replies: [.committed(value: CloudJSON.linkToken(), revision: 0)])
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await session.prepare(hostID: host, service: .daemon)
        await api.holdNextMutation()
        let first = Task { try await session.mintHelloToken() }
        await api.waitForHeld()
        let second = Task { try await session.mintHelloToken() }
        await #expect(throws: CloudAttachSessionError.operationInProgress) {
            _ = try await second.value
        }
        await api.release()
        _ = try await first.value
        #expect(await api.count("cloud.machine.link_token") == 1)
    }

    @Test func concurrentPreparesDoNotReplaceTheInFlightPlan() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.holdNextRead()
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        let first = Task { try await session.prepare(hostID: host, service: .daemon) }
        await api.waitForHeldRead()
        let second = Task { try await session.prepare(hostID: host, service: .ssh) }
        await #expect(throws: CloudAttachSessionError.operationInProgress) {
            _ = try await second.value
        }
        await api.releaseRead()
        guard case .ready(let plan) = try await first.value else {
            Issue.record("first prepare should complete")
            return
        }
        #expect(plan.service == .daemon)
        #expect(await api.count("cloud.machine.connect_info") == 1)
    }

    @Test func prepareCannotOverwriteAPlanWhileItsGrantIsMinting() async throws {
        let api = FakeCloudAPI()
        await api.setConnectInfo(connectInfo())
        await api.set(replies: [.committed(value: CloudJSON.linkToken(), revision: 0)])
        let session = CloudAttachSession(api: api, now: { Date(timeIntervalSince1970: 1_000) })
        _ = try await session.prepare(hostID: host, service: .daemon)
        await api.holdNextMutation()
        let mint = Task { try await session.mintHelloToken() }
        await api.waitForHeld()
        await #expect(throws: CloudAttachSessionError.operationInProgress) {
            _ = try await session.prepare(hostID: host, service: .ssh)
        }
        await api.release()
        _ = try await mint.value
        #expect(await api.count("cloud.machine.connect_info") == 1)
    }

    @Test func linkTokenDecoderAcceptsDecimalExpiryAndRejectsMissingSecret() throws {
        let decoder = CloudWireDecoder()
        let value = CloudJSON.linkToken(expiresAt: 2_000_000_000_000)
        let grant = try decoder.linkToken(value)
        #expect(grant.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(throws: CloudWireDecodeError.invalidLinkToken) {
            try decoder.linkToken(CloudJSON.linkToken(token: ""))
        }
    }

    @Test func linkTokenMutationBodyOmitsIdempotencyKeyButRegularMutationsKeepIt() {
        let tokenBody = URLSessionCloudAPIClient.mutationBody(op: "cloud.machine.link_token", params: [:], key: "")
        #expect(tokenBody["idempotency_key"] == nil)
        let regularBody = URLSessionCloudAPIClient.mutationBody(op: "cloud.machine.pause", params: [:], key: "intent-1")
        #expect(regularBody["idempotency_key"] == .string("intent-1"))
    }
}
