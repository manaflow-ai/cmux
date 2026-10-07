import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// Real Macs before a carrier fills `FileHostConnector`: every read says
/// there is no connection, so real workspaces never show mock content.
public struct UnavailableViewerContentSource: ViewerContentSource {
    public init() {}

    public func roots(host: HostID) async throws -> [FilesRoot] { throw ViewerSourceError.noConnection }
    public func list(host: HostID, path: String, after: String?) async throws -> FilesListResult { throw ViewerSourceError.noConnection }
    public func status(host: HostID, path: String) async throws -> GitStatusResult { throw ViewerSourceError.noConnection }
    public func diff(host: HostID, params: GitDiffParams) async throws -> GitDiffResult { throw ViewerSourceError.noConnection }
    public func fetch(host: HostID, path: String, size: UInt64?) async throws -> URL { throw ViewerSourceError.noConnection }
}
