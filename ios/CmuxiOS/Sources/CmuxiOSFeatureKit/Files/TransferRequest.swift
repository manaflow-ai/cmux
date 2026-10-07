public import Foundation

/// One upload or download between this device and a host.
public struct TransferRequest: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        case upload(localURL: URL)
        case download(localURL: URL)
    }

    public var id: TransferID
    public var hostID: HostID
    public var direction: Direction
    /// Download: the Mac path. Upload: ignored (see `destination`).
    public var remotePath: String
    public var byteCount: Int64?
    /// Upload only.
    public var destination: TransferDestination
    /// Shown in the list and used as the uploaded file's name; defaults to the local file name.
    public var name: String?
    public var mime: String?

    public init(id: TransferID = TransferID(), hostID: HostID, direction: Direction, remotePath: String = "",
                byteCount: Int64? = nil, destination: TransferDestination = .composer, name: String? = nil,
                mime: String? = nil) {
        self.id = id
        self.hostID = hostID
        self.direction = direction
        self.remotePath = remotePath
        self.byteCount = byteCount
        self.destination = destination
        self.name = name
        self.mime = mime
    }

    public var localURL: URL {
        switch direction {
        case .upload(let url), .download(let url): url
        }
    }

    public var isUpload: Bool {
        if case .upload = direction { return true }
        return false
    }

    public var displayName: String { name ?? localURL.lastPathComponent }
}
