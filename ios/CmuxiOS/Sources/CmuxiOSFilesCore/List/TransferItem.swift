import CmuxiOSFeatureKit
import Foundation

/// One row of the transfer list: the request, its latest progress and a
/// smoothed speed from successive reports (view state only).
public struct TransferItem: Hashable, Sendable, Identifiable {
    public var request: TransferRequest
    public var progress: TransferProgress
    public var bytesPerSecond: Double?
    var lastSample: (bytes: Int64, at: ContinuousClock.Instant)?

    public var id: TransferID { request.id }

    public init(request: TransferRequest, progress: TransferProgress) {
        self.request = request
        self.progress = progress
    }

    public var isRunning: Bool { progress.state == .running }

    /// Paused or failed transfers can resume (failed ones restart where the bytes end).
    public var canResume: Bool {
        switch progress.state {
        case .paused, .failed: true
        case .running, .finished, .cancelled: false
        }
    }

    mutating func apply(_ next: TransferProgress, at now: ContinuousClock.Instant) {
        if let last = lastSample, next.state == .running {
            let seconds = Double((now - last.at).components.attoseconds) / 1e18 + Double((now - last.at).components.seconds)
            if seconds >= 0.25 {
                let rate = Double(next.completedBytes - last.bytes) / seconds
                bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + rate * 0.3 } ?? rate
                lastSample = (next.completedBytes, now)
            }
        } else {
            lastSample = (next.completedBytes, now)
        }
        if next.state != .running { bytesPerSecond = nil }
        progress = next
    }

    public static func == (lhs: TransferItem, rhs: TransferItem) -> Bool {
        lhs.request == rhs.request && lhs.progress == rhs.progress && lhs.bytesPerSecond == rhs.bytesPerSecond
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(request.id)
    }
}
