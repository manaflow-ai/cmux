public import Foundation

/// Immutable inputs used to bind one native Iroh endpoint.
///
/// The configuration deliberately contains values rather than IrohLib objects.
/// That keeps endpoint construction in one place and makes key custody and
/// relay policy explicit at the call site.
public struct IrohLibConfiguration: Equatable, Sendable {
    /// The relay policy used while binding the endpoint.
    public enum RelayMode: Equatable, Sendable {
        /// Use the n0 production relay and discovery preset.
        case production

        /// Use the n0 staging relay and discovery preset.
        case staging

        /// Disable relays and discovery. Direct addresses still work.
        case disabled
    }

    /// Configuration validation failures.
    public enum Failure: Error, Equatable, Sendable {
        /// Iroh requires a nonempty ALPN protocol identifier.
        case emptyALPN

        /// A supplied secret key must contain exactly 32 bytes.
        case invalidSecretKeyLength(Int)

        /// Native reads need a positive upper bound.
        case invalidReceiveChunkLimit
    }

    /// A conservative default for the cmux-lite protocol.
    public static let standard = IrohLibConfiguration(
        uncheckedALPN: Data("dev.cmux.cmux-lite/1".utf8),
        relayMode: .production,
        secretKeyBytes: nil,
        maximumReceiveChunkBytes: 64 * 1024
    )

    /// The ALPN negotiated by both peers.
    public let alpn: Data

    /// The relay/discovery mode for the endpoint.
    public let relayMode: RelayMode

    /// Optional caller-owned 32-byte endpoint key material.
    ///
    /// The provider does not persist or generate this value. A later Keychain
    /// slice will supply it here and retain ownership outside the binding.
    public let secretKeyBytes: Data?

    /// Maximum number of bytes returned by one native receive operation.
    public let maximumReceiveChunkBytes: UInt32

    /// Creates a validated endpoint configuration.
    public init(
        alpn: Data,
        relayMode: RelayMode = .production,
        secretKeyBytes: Data? = nil,
        maximumReceiveChunkBytes: UInt32 = 64 * 1024
    ) throws {
        guard !alpn.isEmpty else {
            throw Failure.emptyALPN
        }
        if let secretKeyBytes, secretKeyBytes.count != 32 {
            throw Failure.invalidSecretKeyLength(secretKeyBytes.count)
        }
        guard maximumReceiveChunkBytes > 0 else {
            throw Failure.invalidReceiveChunkLimit
        }

        self.alpn = Data(alpn)
        self.relayMode = relayMode
        self.secretKeyBytes = secretKeyBytes.map { Data($0) }
        self.maximumReceiveChunkBytes = maximumReceiveChunkBytes
    }

    private init(
        uncheckedALPN alpn: Data,
        relayMode: RelayMode,
        secretKeyBytes: Data?,
        maximumReceiveChunkBytes: UInt32
    ) {
        self.alpn = alpn
        self.relayMode = relayMode
        self.secretKeyBytes = secretKeyBytes
        self.maximumReceiveChunkBytes = maximumReceiveChunkBytes
    }
}
