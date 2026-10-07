import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import CmuxMobileLink
import CmuxMobileWire
import CryptoKit
import Foundation

/// The real `ViewerContentSource`: reads over the host's one
/// `MobileLinkClient` (C4's `FileHostConnector`), downloads through the
/// `FileTransfer` seam into `Caches/cmux-viewers/<host>/<path hash>/`.
public struct LinkViewerContentSource: ViewerContentSource {
    let connector: any FileHostConnector
    let transfer: any FileTransfer
    let cacheDirectory: URL

    public init(connector: any FileHostConnector, transfer: any FileTransfer, cacheDirectory: URL? = nil) {
        self.connector = connector
        self.transfer = transfer
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
    }

    public static var defaultCacheDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("cmux-viewers", isDirectory: true)
    }

    public func roots(host: HostID) async throws -> [FilesRoot] {
        try await read(host, "files.roots", params: .object([:]), as: FilesRootsResult.self).roots
    }

    public func list(host: HostID, path: String, after: String?) async throws -> FilesListResult {
        try await read(host, "files.list", params: JSONValue(encoding: FilesListParams(path: path, after: after)), as: FilesListResult.self)
    }

    public func status(host: HostID, path: String) async throws -> GitStatusResult {
        try await read(host, "git.status", params: JSONValue(encoding: GitStatusParams(path: path)), as: GitStatusResult.self)
    }

    public func diff(host: HostID, params: GitDiffParams) async throws -> GitDiffResult {
        try await read(host, "git.diff", params: JSONValue(encoding: params), as: GitDiffResult.self)
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
            case .cancelled, .paused: throw CancellationError()
            case .running: continue
            }
        }
        throw ViewerSourceError.failed("download ended early")
    }

    func localURL(host: HostID, path: String) -> URL {
        let digest = SHA256.hash(data: Data((host.rawValue + "\n" + path).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = (path as NSString).lastPathComponent
        return cacheDirectory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(name.isEmpty ? "file" : name)
    }

    private func read<T: Decodable>(_ host: HostID, _ op: String, params: JSONValue, as type: T.Type) async throws -> T {
        let client: MobileLinkClient
        do {
            client = try await connector.client(for: host)
        } catch {
            throw ViewerSourceError.noConnection
        }
        do {
            return try await client.read(op, params: params).decode(as: type)
        } catch MobileLinkClientError.refused(let code, let message, _) {
            throw ViewerSourceError(code: code, message: message)
        } catch MobileLinkClientError.linkLost, MobileLinkClientError.closed {
            throw ViewerSourceError.noConnection
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ViewerSourceError {
            throw error
        } catch {
            throw ViewerSourceError.failed(String(describing: error))
        }
    }
}
