import Foundation
import Observation

/// The one "now" every relative time reads (Workspaces rows, filter and
/// alerts, Settings → Devices): it ticks on each minute mark, so every
/// surface formats the same Mac against the same instant and redraws
/// together. Observable: a view that reads `now` refreshes on the tick.
@MainActor
@Observable
public final class MinuteClock {
    public static let shared = MinuteClock()

    /// The time of the latest tick (launch, then each minute mark). Not
    /// rounded: a Mac seen 3 days before launch reads "3d", not "2d".
    public private(set) var now: Date
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// `ticking: false` holds `now` (tests).
    public init(now: Date = Date(), ticking: Bool = true) {
        self.now = now
        if ticking { start() }
    }

    /// The minute mark at or before `date`.
    public nonisolated static func mark(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func start() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // An intentional, bounded wait: until the next minute mark.
                let next = Self.mark(Date()).addingTimeInterval(60)
                try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
                guard let self, !Task.isCancelled else { return }
                self.now = Date()
            }
        }
    }
}
