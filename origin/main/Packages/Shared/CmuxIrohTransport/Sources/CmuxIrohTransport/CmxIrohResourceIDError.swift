/// Validation failures for identifiers carried in Iroh stream headers.
public enum CmxIrohResourceIDError: Error, Equatable, Sendable {
    /// The identifier is empty, too long, or contains a non-protocol character.
    case invalidValue
}
