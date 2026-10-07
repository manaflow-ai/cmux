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
}
