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
    /// Called when a transfer ends for good: finished, cancelled or failed
    /// without a retry (staging cleanup).
    @ObservationIgnored public var onEnded: ((TransferItem) -> Void)?
    @ObservationIgnored private let transfer: any FileTransfer
    @ObservationIgnored private var runs: [TransferID: (token: UUID, task: Task<Void, Never>)] = [:]
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
        let live = runs[id] != nil
        Task { [weak self] in
            await transfer.cancel(id)
            // A paused transfer has no stream to report it; mark it here.
            guard !live, let self, let item = self.items.first(where: { $0.id == id }), item.canResume else { return }
            var cancelled = item.progress
            cancelled.state = .cancelled
            self.apply(cancelled)
        }
    }

    /// Resumes every transfer an interruption paused (back in the foreground).
    public func resumeInterrupted() {
        for item in items where item.progress.state == .paused && runs[item.id] == nil {
            resume(item.id)
        }
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
        runs[id]?.task.cancel()
        let transfer = transfer
        let token = UUID()
        runs[id] = (token, Task { [weak self] in
            do {
                let stream = try await open(transfer)
                for await progress in stream {
                    self?.apply(progress)
                }
            } catch {
                self?.apply(TransferProgress(id: id, completedBytes: 0, totalBytes: nil, state: .failed(reason: "files.unavailable")))
            }
            if self?.runs[id]?.token == token { self?.runs[id] = nil }
        })
    }

    private func apply(_ progress: TransferProgress) {
        guard let index = items.firstIndex(where: { $0.id == progress.id }) else { return }
        let wasEnded = items[index].progress.state.isTerminal
        let wasFinished = items[index].progress.state == .finished
        var next = progress
        if next.totalBytes == nil { next.totalBytes = items[index].progress.totalBytes }
        if next.remotePath == nil { next.remotePath = items[index].progress.remotePath }
        items[index].apply(next, at: clock.now)
        if next.state == .finished, !wasFinished { onFinished?(items[index]) }
        if next.state.isTerminal, !wasEnded { onEnded?(items[index]) }
    }
}
