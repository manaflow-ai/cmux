import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// Reads and validates `cloud.machine.connect_info` before opening a VM link.
/// This is the phase-2 seam: carrier setup and one-shot link-token minting are
/// intentionally separate operations owned by the link layer.
public struct CloudAttachPreflight: Sendable {
    private let api: any CloudAPIClient
    private let decoder: CloudWireDecoder

    public init(api: any CloudAPIClient, decoder: CloudWireDecoder = CloudWireDecoder()) {
        self.api = api
        self.decoder = decoder
    }

    public func resolve(
        machineID: String? = nil,
        hostID: HostID? = nil,
        service: CloudConnectInfo.Service,
        expectedMachine: CloudMachine? = nil
    ) async throws -> CloudAttachDecision {
        // CloudDO requires exactly one selector. Do this locally so a malformed
        // attach cannot accidentally broaden to a team-wide lookup.
        guard (machineID == nil) != (hostID == nil) else {
            throw CloudAPIError.refused(code: "validation.invalid")
        }
        var params: [String: JSONValue] = [:]
        if let machineID { params["machine"] = .string(machineID) }
        if let hostID { params["host"] = .string(hostID.rawValue) }
        let value = try await api.read("cloud.machine.connect_info", params: params)
        let info = try decoder.connectInfo(value)
        return try CloudAttachPlanner.plan(
            info: info,
            service: service,
            expectedMachine: expectedMachine,
            expectedHost: hostID
        )
    }
}
