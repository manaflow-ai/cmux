/// A file the Mac holds after an upload, handed to the composer (C8) or any
/// other consumer of uploaded files.
public struct FileAttachment: Hashable, Sendable, Identifiable {
    public var id: TransferID
    public var hostID: HostID
    /// Absolute path on the Mac (`files.upload.done.path`).
    public var remotePath: String
    /// The owner-issued `up_` reference. A remote path is never a substitute.
    public var uploadID: String?
    public var name: String
    public var mime: String
    public var byteCount: Int64

    public init(id: TransferID, hostID: HostID, remotePath: String, name: String, mime: String, byteCount: Int64,
                uploadID: String? = nil) {
        self.id = id
        self.hostID = hostID
        self.remotePath = remotePath
        self.uploadID = uploadID
        self.name = name
        self.mime = mime
        self.byteCount = byteCount
    }
}
