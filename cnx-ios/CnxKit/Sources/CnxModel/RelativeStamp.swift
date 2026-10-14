import Foundation

/// Compact relative times (SPEC 11.1 `meta`): "now", "4m", "3h", "2d", then
/// a short date. The one formatter for a Mac's "Last seen" on every surface
/// (Workspaces rows and filter, Settings → Devices). Both times are counted in
/// whole minutes, so two surfaces formatting the same Mac within one minute
/// always agree (a cache keyed by the minute included).
public struct RelativeStamp: Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public func string(for date: Date) -> String {
        let seconds = max(0, Self.minute(now) - Self.minute(date))
        switch seconds {
        // Two minute marks apart at most: under a minute or two of real time
        // (whole minutes are counted, so 20 s can span a minute mark).
        case ..<120: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default:
            var style = Date.FormatStyle(date: .numeric, time: .omitted)
            style.calendar = calendar
            return date.formatted(style)
        }
    }

    private static func minute(_ date: Date) -> TimeInterval {
        (date.timeIntervalSince1970 / 60).rounded(.down) * 60
    }

    /// "Online", or "Last seen 2h ago" for an offline Mac.
    public func presence(isOnline: Bool, lastSeenAt: Date?) -> String {
        if isOnline { return "Online" }
        guard let lastSeenAt else { return "Offline" }
        let value = string(for: lastSeenAt)
        return value == "now" ? "Last seen just now" : (value.count <= 4 ? "Last seen \(value) ago" : "Last seen \(value)")
    }
}
