import CmuxiOSFeatureKit

/// Writes a viewer source supports on top of reading (SFTP hosts, lane E5).
/// The Mac's `files.*` wire has none, so its source does not conform and
/// the file browser hides New Folder, Rename and Delete there.
public protocol ViewerFileOperations: Sendable {
    func makeDirectory(host: HostID, path: String) async throws
    func rename(host: HostID, from source: String, to destination: String) async throws
    /// Removes a file, or an empty directory when `isDirectory`.
    func remove(host: HostID, path: String, isDirectory: Bool) async throws
}
