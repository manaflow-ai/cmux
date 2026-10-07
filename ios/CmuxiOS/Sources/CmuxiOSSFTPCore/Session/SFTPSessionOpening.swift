/// Opens (and reopens) one host's SFTP session. The connection is made on
/// first use and kept while the host's files screen is open; after a drop
/// the next call reconnects. No timer keeps it alive.
public protocol SFTPSessionOpening: Sendable {
    func fileSystem() async throws -> any SFTPFileSystem
    /// Drops the current session (it was lost); the next call reconnects.
    func reset() async
    func close() async
}
