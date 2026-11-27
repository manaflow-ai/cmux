import Foundation

/// Timestamps on list rows and search hits: the time today, "Yesterday",
/// the weekday within the last week, then a short date. Pure, so it is
/// testable with a fixed `now`, calendar and locale.
struct HomeTimeFormatting: Sendable {
    var calendar: Calendar
    var locale: Locale

    init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    enum Bucket: Equatable, Sendable {
        case today
        case yesterday
        case thisWeek
        case older
    }

    func bucket(for date: Date, now: Date) -> Bucket {
        if calendar.isDate(date, inSameDayAs: now) || date > now { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return .older }
        if date >= startOfYesterday { return .yesterday }
        guard let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) else { return .older }
        return date >= weekAgo ? .thisWeek : .older
    }

    /// The short label a row shows.
    func rowLabel(for date: Date, now: Date) -> String {
        switch bucket(for: date, now: now) {
        case .today:
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        case .yesterday:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: date)
        case .thisWeek:
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.wide))
        case .older:
            return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        }
    }

    /// The spoken form for VoiceOver ("12 minutes ago").
    func spokenLabel(for date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        if abs(now.timeIntervalSince(date)) < 60 {
            formatter.dateTimeStyle = .named
            return formatter.localizedString(fromTimeInterval: 0)
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
