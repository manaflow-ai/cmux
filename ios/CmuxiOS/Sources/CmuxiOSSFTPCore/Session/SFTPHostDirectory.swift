public import CmuxiOSFeatureKit
import CmuxMobileSSH

/// The SFTP session per SSH host, shared by the host's file browser,
/// viewers and transfers. The Hosts tab registers a host's opener when its
/// files screen opens and closes it when the screen goes away; a lost
/// session is dropped so the next call reconnects.
public actor SFTPHostDirectory {
    public enum Failure: Error, Hashable, Sendable {
        /// The host's files screen is not open (nothing registered).
        case noSession
    }

    private var openers: [HostID: (lease: UUID, opener: any SFTPSessionOpening)] = [:]

    public init() {}

    /// Makes `opener` the host's session (closing an earlier one) and
    /// returns the lease that `release` needs, so a screen that goes away
    /// late never closes the session a newer screen registered.
    @discardableResult
    public func register(_ opener: any SFTPSessionOpening, for host: HostID) async -> UUID {
        let lease = UUID()
        let previous = openers[host]
        openers[host] = (lease, opener)
        await previous?.opener.close()
        return lease
    }

    /// Closes the host's session if `lease` is still the current one.
    public func release(_ host: HostID, lease: UUID) async {
        guard openers[host]?.lease == lease else { return }
        await close(host)
    }

    public func close(_ host: HostID) async {
        await openers.removeValue(forKey: host)?.opener.close()
    }

    public func closeAll() async {
        for host in Array(openers.keys) { await close(host) }
    }

    public func isRegistered(_ host: HostID) -> Bool { openers[host] != nil }

    /// Runs `body` on the host's session; a lost session is reset first and
    /// the error rethrown (the caller decides whether to retry).
    public func run<T: Sendable>(_ host: HostID, _ body: @Sendable (any SFTPFileSystem) async throws -> T) async throws -> T {
        guard let opener = openers[host]?.opener else { throw Failure.noSession }
        let system = try await opener.fileSystem()
        do {
            return try await body(system)
        } catch SFTPError.connectionLost {
            await opener.reset()
            throw SFTPError.connectionLost
        }
    }
}
