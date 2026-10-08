import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// Errors raised while turning a preflight plan into a one-shot VM hello.
public enum CloudAttachSessionError: Error, Hashable, Sendable {
    case notPrepared
    case credentialAlreadyIssued
    case invalidGrant
    case expiredGrant
}

/// The phase-2 phone-side boundary shared by terminal, workspace and file
/// attachment. It owns no carrier and stores no credential. A caller prepares
/// a plan, mints one daemon grant, consumes it when opening the underlying
/// `CmuxLink`, and calls `resetForReconnect()` before preparing again after a
/// link loss.
public actor CloudAttachSession {
    private let api: any CloudAPIClient
    private let preflight: CloudAttachPreflight
    private let decoder: CloudWireDecoder
    private let now: @Sendable () -> Date
    private var plan: CloudAttachPlan?
    private var issued = false

    public init(api: any CloudAPIClient, decoder: CloudWireDecoder = CloudWireDecoder(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        preflight = CloudAttachPreflight(api: api, decoder: decoder)
        self.decoder = decoder
        self.now = now
    }

    /// Re-reads point-in-time peer data and records the plan only when the VM
    /// is running. A paused VM never reaches `link_token`; the UI can ask the
    /// person to resume it and call this method again after the upsert.
    @discardableResult
    public func prepare(machineID: String? = nil, hostID: HostID? = nil,
                        service: CloudConnectInfo.Service,
                        expectedMachine: CloudMachine? = nil) async throws -> CloudAttachDecision {
        issued = false
        plan = nil
        let decision = try await preflight.resolve(machineID: machineID, hostID: hostID,
                                                   service: service, expectedMachine: expectedMachine)
        if case .ready(let ready) = decision { plan = ready }
        return decision
    }

    /// Mints a fresh install-scoped credential for the prepared daemon plan.
    /// Passing an empty idempotency key is intentional: this operation is
    /// explicitly non-idempotent and every retry must mint a new token.
    public func mintHelloToken() async throws -> CloudLinkTokenGrant {
        guard let plan else { throw CloudAttachSessionError.notPrepared }
        guard !issued else { throw CloudAttachSessionError.credentialAlreadyIssued }
        let reply = try await api.mutate(
            "cloud.machine.link_token",
            params: [
                "host": .string(plan.info.hostID.rawValue),
                "services": .array([.string(plan.service.rawValue)]),
            ],
            key: "",
            as: .install)
        let value: JSONValue
        switch reply {
        case .committed(let committed, _): value = committed
        case .rejected(let code, _): throw CloudAPIError.refused(code: code)
        }
        let grant = try decoder.linkToken(value)
        guard grant.hostID == plan.info.hostID,
              grant.epoch == plan.info.epoch,
              grant.services.contains(plan.service) else {
            throw CloudAttachSessionError.invalidGrant
        }
        guard grant.expiresAt > now() else { throw CloudAttachSessionError.expiredGrant }
        issued = true
        return grant
    }

    /// A reconnect must perform a new connect-info read and mint. This clears
    /// only local state; any returned token is owned by the link caller and is
    /// never retained here.
    public func resetForReconnect() {
        issued = false
        plan = nil
    }
}
