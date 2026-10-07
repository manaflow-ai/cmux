/// A transfer as the list shows it after a relaunch: the request and its
/// last known progress.
public struct TransferSnapshot: Hashable, Sendable {
    public var request: TransferRequest
    public var progress: TransferProgress

    public init(request: TransferRequest, progress: TransferProgress) {
        self.request = request
        self.progress = progress
    }
}
