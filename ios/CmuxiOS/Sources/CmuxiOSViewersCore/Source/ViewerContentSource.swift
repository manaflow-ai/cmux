import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// Seam for lane C13: everything the viewers read from a Mac. Reads are
/// answered by the Mac at request time (no mirror); `fetch` downloads a
/// file through C4 and returns its local copy.
public protocol ViewerContentSource: Sendable {
    /// Folders this device may browse (inbox first, then one per workspace, id = workspace id).
    func roots(host: HostID) async throws -> [FilesRoot]
    func list(host: HostID, path: String, after: String?) async throws -> FilesListResult
    func status(host: HostID, path: String) async throws -> GitStatusResult
    func diff(host: HostID, params: GitDiffParams) async throws -> GitDiffResult
    func fetch(host: HostID, path: String, size: UInt64?) async throws -> URL
}

extension ViewerContentSource {
    /// The workspace's folder: the root whose id is the workspace id.
    public func workspaceRoot(for target: ViewerTarget) async throws -> FilesRoot {
        guard let root = try await roots(host: target.hostID).first(where: { $0.id == target.workspaceID }) else {
            throw ViewerSourceError.noWorkspaceFolder
        }
        return root
    }
}
