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
    public var remotePath: String
    public var byteCount: Int64?

    public init(id: TransferID = TransferID(), hostID: HostID, direction: Direction, remotePath: String, byteCount: Int64? = nil) {
        self.id = id
        self.hostID = hostID
        self.direction = direction
        self.remotePath = remotePath
        self.byteCount = byteCount
    }
}
