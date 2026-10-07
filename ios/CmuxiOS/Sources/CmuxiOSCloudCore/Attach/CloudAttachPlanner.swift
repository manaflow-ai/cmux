import CmuxiOSFeatureKit
import Foundation

/// Validates the state and identity invariants shared by all VM carriers.
/// This is deliberately pure so the phase-2 VM host can be integrated without
/// making the Cloud tab or a carrier responsible for lifecycle policy.
public enum CloudAttachPlanner {
    public static func plan(
        info: CloudConnectInfo,
        service: CloudConnectInfo.Service,
        expectedMachine: CloudMachine? = nil,
        expectedHost: HostID? = nil
    ) throws -> CloudAttachDecision {
        if let expectedMachine, expectedMachine.id != info.machineID {
            throw CloudAttachValidationError.machineMismatch
        }
        if let expectedHost, expectedHost != info.hostID {
            throw CloudAttachValidationError.hostMismatch
        }
        guard info.machineID.hasPrefix("vm_"), info.hostID.rawValue.hasPrefix("host_") else {
            throw CloudAttachValidationError.invalidIdentity
        }
        if let expectedMachine, let machineHost = expectedMachine.host, machineHost != info.hostID {
            throw CloudAttachValidationError.hostMismatch
        }
        guard info.epoch > 0 else { throw CloudAttachValidationError.invalidEpoch }
        guard validPeer(info.peer) else { throw CloudAttachValidationError.invalidPeer }
        guard info.services.contains(service) else {
            throw CloudAttachValidationError.serviceUnavailable(service)
        }

        switch info.state {
        case .paused, .pausing, .starting:
            return .resumeRequired(info.state)
        case .running:
            return .ready(CloudAttachPlan(info: info, service: service))
        case .provisioning, .deleting, .failed:
            throw CloudAttachValidationError.unavailable(info.state)
        }
    }

    private static func validPeer(_ peer: CloudConnectInfo.Peer) -> Bool {
        // The protocol defines a 32-byte base64 WireGuard key and the
        // fd7c:6d78::/32 overlay. Keep this check dependency-free so the core
        // package remains Foundation-only on macOS and iOS.
        guard !peer.wireGuardPublicKey.isEmpty,
              Data(base64Encoded: peer.wireGuardPublicKey)?.count == 32,
              peer.overlayAddress.lowercased().hasPrefix("fd7c:6d78:") else {
            return false
        }
        return true
    }
}
