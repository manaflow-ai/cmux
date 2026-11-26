/// Canonical registration bytes retained across the challenge round trip.
public struct CmxIrohPreparedRegistration: Equatable, Sendable {
    /// Request body for `/api/devices/iroh/challenge`.
    public let challengeRequest: CmxIrohChallengeRequest
    /// Base64url-encoded registration payload.
    public let encodedPayload: String
    /// SHA-256 of the decoded payload bytes.
    public let payloadSHA256: String
    /// Exact endpoint identity declared by the payload.
    public let endpointID: String

    init(
        challengeRequest: CmxIrohChallengeRequest,
        encodedPayload: String,
        payloadSHA256: String,
        endpointID: String
    ) {
        self.challengeRequest = challengeRequest
        self.encodedPayload = encodedPayload
        self.payloadSHA256 = payloadSHA256
        self.endpointID = endpointID
    }
}
