/// Validation failures for an Iroh endpoint bind configuration.
public enum CmxIrohEndpointConfigurationError: Error, Equatable, Sendable {
    /// The relay fleet is larger than the endpoint policy permits.
    case tooManyRelays(Int)

    /// A relay URL appears more than once.
    case duplicateRelayURL(String)

    /// A credential names a relay outside the explicit fleet allowlist.
    case unmanagedRelayURL(String)

    /// A verified managed selection is missing one or more relay credentials.
    case incompleteManagedRelayCredentials

    /// Managed broker credentials cannot mutate a strict custom relay override.
    case managedCredentialUpdateInCustomProfile

    /// The endpoint implementation cannot apply a complete profile replacement.
    case unsupportedRelayProfileReplacement
}
