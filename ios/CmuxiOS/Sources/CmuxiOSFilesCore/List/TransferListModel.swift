import CmuxiOSFeatureKit
import Foundation
import Observation

/// The phone's transfer list (client view state over the `FileTransfer`
/// seam): starts, cancels and resumes transfers and folds their progress.
/// Works the same on the mock and the real seam.
@MainActor
@Observable
public final class TransferListModel {
    public private(set) var items: [TransferItem] = []
    /// Called once per transfer when it finishes (send-to-terminal, attach).
    @ObservationIgnored public var onFinished: ((TransferItem) -> Void)?
    @ObservationIgnored private let transfer: any FileTransfer
    @ObservationIgnored private var runs: [TransferID: Task<Void, Never>] = [:]
    @ObservationIgnored private let clock = ContinuousClock()

    public init(transfer: any FileTransfer) {
        self.transfer = transfer
    }

    /// Restores transfers from earlier runs (once, at screen load).
    public func load() async {
        let known = Set(items.map(\.id))
        let restored = await transfer.history().filter { !known.contains($0.request.id) }
        items.append(contentsOf: restored.map { TransferItem(request: $0.request, progress: $0.progress) })
    }

    public var hasRunning: Bool { items.contains(where: \.isRunning) }

    public func start(_ request: TransferRequest) {
        let initial = TransferProgress(id: request.id, completedBytes: 0, totalBytes: request.byteCount, state: .running)
        items.insert(TransferItem(request: request, progress: initial), at: 0)
        run(request.id) { transfer in try await transfer.start(request) }
    }

    public func resume(_ id: TransferID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].canResume else { return }
        items[index].progress.state = .running
        run(id) { transfer in try await transfer.resume(id) }
    }

    public func cancel(_ id: TransferID) {
        let transfer = transfer
        Task { await transfer.cancel(id) }
    }

    /// Drops a finished, failed or cancelled row.
    public func remove(_ id: TransferID) {
        guard let item = items.first(where: { $0.id == id }), !item.isRunning else { return }
        items.removeAll { $0.id == id }
    }

    public func pauseAll() async {
        await transfer.pauseAll()
    }

    // MARK: Private

    private func run(_ id: TransferID, _ open: @escaping @Sendable (any FileTransfer) async throws -> AsyncStream<TransferProgress>) {
        runs[id]?.cancel()
        let transfer = transfer
        runs[id] = Task { [weak self] in
            do {
                let stream = try await open(transfer)
                for await progress in stream {
                    self?.apply(progress)
                }
            } catch {
                self?.apply(TransferProgress(id: id, completedBytes: 0, totalBytes: nil, state: .failed(reason: "files.unavailable")))
            }
            self?.runs[id] = nil
        }
    }

    private func apply(_ progress: TransferProgress) {
        guard let index = items.firstIndex(where: { $0.id == progress.id }) else { return }
        let wasFinished = items[index].progress.state == .finished
        var next = progress
        if next.totalBytes == nil { next.totalBytes = items[index].progress.totalBytes }
        if next.remotePath == nil { next.remotePath = items[index].progress.remotePath }
        items[index].apply(next, at: clock.now)
        if next.state == .finished, !wasFinished { onFinished?(items[index]) }
    }
}
