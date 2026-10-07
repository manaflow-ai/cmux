public import CmuxiOSFeatureKit
public import CmuxiOSViewersCore
import CmuxMobileSSH
public import CmuxMobileWire
import CryptoKit
public import Foundation

/// C13's `ViewerContentSource` for an SSH host (lane E5): one root, the
/// login directory; listings from SFTP `readdir` (symlinks listed, never
/// followed); no git; files downloaded through `SFTPFileTransfer` into the
/// viewers cache. It also writes (New Folder, Rename, Delete).
public struct SFTPViewerContentSource: ViewerContentSource, ViewerFileOperations {
    /// The id of the single root, used as the browser target's workspace id.
    public static let rootID = "sftp.home"

    let directory: SFTPHostDirectory
    let transfer: any FileTransfer
    let cacheDirectory: URL

    public init(directory: SFTPHostDirectory, transfer: any FileTransfer, cacheDirectory: URL? = nil) {
        self.directory = directory
        self.transfer = transfer
        self.cacheDirectory = cacheDirectory ?? LinkViewerContentSource.defaultCacheDirectory.appendingPathComponent("sftp", isDirectory: true)
    }

    public func roots(host: HostID) async throws -> [FilesRoot] {
        let home = try await perform(host) { try await $0.realpath(".") }
        let name = (home as NSString).lastPathComponent
        return [FilesRoot(id: Self.rootID, name: name.isEmpty ? home : name, path: home, writable: true)]
    }

    public func list(host: HostID, path: String, after: String?) async throws -> FilesListResult {
        // One page: SFTP lists a folder in one READDIR loop.
        guard after == nil else { return FilesListResult(entries: []) }
        let entries = try await perform(host) { try await $0.listDirectory(path) }
        return FilesListResult(entries: entries.map(Self.entry))
    }

    public func status(host: HostID, path: String) async throws -> GitStatusResult {
        throw ViewerSourceError.notARepository
    }

    public func diff(host: HostID, params: GitDiffParams) async throws -> GitDiffResult {
        throw ViewerSourceError.notARepository
    }

    public func fetch(host: HostID, path: String, size: UInt64?) async throws -> URL {
        let local = localURL(host: host, path: path)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let request = TransferRequest(hostID: host, direction: .download(localURL: local), remotePath: path,
                                      byteCount: size.map(Int64.init), name: local.lastPathComponent)
        for await progress in try await transfer.start(request) {
            switch progress.state {
            case .finished: return local
            case .failed(let reason): throw ViewerSourceError(code: reason, message: reason)
            case .paused: throw ViewerSourceError.noConnection
            case .cancelled: throw CancellationError()
            case .running: continue
            }
        }
        throw ViewerSourceError.failed("download ended early")
    }

    // MARK: Writes

    public func makeDirectory(host: HostID, path: String) async throws {
        try await perform(host) { try await $0.mkdir(path, permissions: nil) }
    }

    public func rename(host: HostID, from source: String, to destination: String) async throws {
        try await perform(host) { try await $0.rename(source, to: destination) }
    }

    public func remove(host: HostID, path: String, isDirectory: Bool) async throws {
        try await perform(host) { system in
            if isDirectory { try await system.rmdir(path) } else { try await system.remove(path) }
        }
    }

    // MARK: Helpers

    static func entry(_ entry: SFTPEntry) -> FilesListEntry {
        let kind: FilesListEntry.Kind = entry.isSymlink ? .symlink : entry.isDirectory ? .dir : .file
        let modified = entry.attributes.modificationTime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return FilesListEntry(name: entry.name, kind: kind, size: entry.attributes.size ?? 0, modifiedAt: modified)
    }

    func localURL(host: HostID, path: String) -> URL {
        let digest = SHA256.hash(data: Data((host.rawValue + "\n" + path).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent
        return cacheDirectory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(name.isEmpty ? "file" : name)
    }

    @discardableResult
    private func perform<T: Sendable>(_ host: HostID, _ body: @escaping @Sendable (any SFTPFileSystem) async throws -> T) async throws -> T {
        do {
            return try await directory.run(host, body)
        } catch {
            throw SFTPViewerError.map(error)
        }
    }
}
