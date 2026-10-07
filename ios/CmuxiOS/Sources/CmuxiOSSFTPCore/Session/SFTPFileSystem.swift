public import CmuxMobileSSH
public import Foundation

/// What the phone's SFTP features use of an SFTP v3 session (lane E5):
/// `SFTPClient` in production, an in-memory tree in tests.
public protocol SFTPFileSystem: Sendable {
    func realpath(_ path: String) async throws -> String
    func stat(_ path: String) async throws -> SFTPAttributes
    func listDirectory(_ path: String) async throws -> [SFTPEntry]
    func mkdir(_ path: String, permissions: UInt32?) async throws
    func remove(_ path: String) async throws
    func rmdir(_ path: String) async throws
    func rename(_ source: String, to destination: String) async throws
    func download(_ remote: String, to localURL: URL, resumeFrom: UInt64,
                  progress: (@Sendable (SFTPTransferProgress) -> Void)?) async throws
    func upload(from localURL: URL, to remote: String, resumeFrom: UInt64,
                progress: (@Sendable (SFTPTransferProgress) -> Void)?) async throws
}

extension SFTPClient: SFTPFileSystem {}
