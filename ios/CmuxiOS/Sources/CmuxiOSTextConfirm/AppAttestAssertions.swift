public import CmuxTextConfirmCore
import DeviceCheck
public import Foundation

/// App Attest assertions for the lowering proof. The attested key id comes
/// from presence-key registration (the attestation goes to the backend
/// route); without one, no assertion is sent and the owner decides.
public struct AppAttestAssertions: AppAttester {
    public enum Failure: Error { case unsupported, noAttestedKey }

    private let keyID: String?

    public init(attestedKeyID: String?) {
        keyID = attestedKeyID
    }

    public func assertion(clientDataHash: Data) async throws -> String {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw Failure.unsupported }
        guard let keyID else { throw Failure.noAttestedKey }
        return try await service.generateAssertion(keyID, clientDataHash: clientDataHash).textConfirmBase64URL
    }
}
