import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CronExpressionTests: XCTestCase {

    // MARK: - Helpers

    /// Create a date from components using a specific timezone.
    private func makeDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)!
    }

    /// Calendar fixed to UTC for deterministic tests.
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // MARK: - Parsing: */5 * * * * (every 5 minutes)

    func testParseEveryFiveMinutes() {
        let cron = CronExpression("*/5 * * * *")
        XCTAssertNotNil(cron)
        XCTAssertEqual(cron!.minutes, Set([0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]))
        XCTAssertEqual(cron!.hours, Set(0...23))
        XCTAssertEqual(cron!.daysOfMonth, Set(1...31))
        XCTAssertEqual(cron!.months, Set(1...12))
        XCTAssertEqual(cron!.daysOfWeek, Set(1...7))
    }

    func testNextFireDateEveryFiveMinutes() {
        let cron = CronExpression("*/5 * * * *")!
        let cal = utcCalendar
        // After 10:02 → next should be 10:05
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 10, minute: 2)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.minute, 5)
    }

    func testNextFireDateEveryFiveMinutesOnBoundary() {
        let cron = CronExpression("*/5 * * * *")!
        let cal = utcCalendar
        // After exactly 10:05:00 → next should be 10:10
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 10, minute: 5)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.minute, 10)
    }

    func testNextFireDateEveryFiveMinutesEndOfHour() {
        let cron = CronExpression("*/5 * * * *")!
        let cal = utcCalendar
        // After 10:57 → next should be 11:00
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 10, minute: 57)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(comps.hour, 11)
        XCTAssertEqual(comps.minute, 0)
    }

    // MARK: - Parsing: 0 9 * * 1-5 (weekday mornings)

    func testParseWeekdayMornings() {
        let cron = CronExpression("0 9 * * 1-5")
        XCTAssertNotNil(cron)
        XCTAssertEqual(cron!.minutes, Set([0]))
        XCTAssertEqual(cron!.hours, Set([9]))
        // Cron 1-5 = Mon-Fri → Calendar 2-6 (2=Mon, 6=Fri)
        XCTAssertEqual(cron!.daysOfWeek, Set([2, 3, 4, 5, 6]))
    }

    func testNextFireDateWeekdayMornings() {
        let cron = CronExpression("0 9 * * 1-5")!
        let cal = utcCalendar
        // 2025-06-15 is a Sunday. Next weekday 9:00 AM should be Monday 2025-06-16
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 8, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: next!)
        XCTAssertEqual(comps.year, 2025)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 16) // Monday
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.weekday, 2) // Monday in Calendar
    }

    func testNextFireDateWeekdayMorningsFromFridayAfternoon() {
        let cron = CronExpression("0 9 * * 1-5")!
        let cal = utcCalendar
        // 2025-06-13 is a Friday, at 10:00 AM (after 9 AM). Next should be Monday 2025-06-16 at 9:00
        let after = makeDate(year: 2025, month: 6, day: 13, hour: 10, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.day, .weekday], from: next!)
        XCTAssertEqual(comps.day, 16) // Monday
        XCTAssertEqual(comps.weekday, 2)
    }

    // MARK: - Parsing: 30 2 * * * (2:30 AM daily)

    func testParseDailyAt230AM() {
        let cron = CronExpression("30 2 * * *")
        XCTAssertNotNil(cron)
        XCTAssertEqual(cron!.minutes, Set([30]))
        XCTAssertEqual(cron!.hours, Set([2]))
        XCTAssertEqual(cron!.daysOfMonth, Set(1...31))
        XCTAssertEqual(cron!.months, Set(1...12))
        XCTAssertEqual(cron!.daysOfWeek, Set(1...7))
    }

    func testNextFireDateDailyAt230AM() {
        let cron = CronExpression("30 2 * * *")!
        let cal = utcCalendar
        // After midnight → should be 2:30 AM same day
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 0, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.day, .hour, .minute], from: next!)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 2)
        XCTAssertEqual(comps.minute, 30)
    }

    func testNextFireDateDailyAt230AMAfterThatTime() {
        let cron = CronExpression("30 2 * * *")!
        let cal = utcCalendar
        // After 3:00 AM → should be next day 2:30 AM
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 3, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.day, .hour, .minute], from: next!)
        XCTAssertEqual(comps.day, 16)
        XCTAssertEqual(comps.hour, 2)
        XCTAssertEqual(comps.minute, 30)
    }

    // MARK: - Invalid expressions

    func testInvalidExpressionTooFewFields() {
        XCTAssertNil(CronExpression("* * *"))
        XCTAssertNil(CronExpression("* * * *"))
    }

    func testInvalidExpressionTooManyFields() {
        XCTAssertNil(CronExpression("* * * * * *"))
    }

    func testInvalidExpressionBadMinute() {
        XCTAssertNil(CronExpression("60 * * * *"))  // minute 60 out of range
        XCTAssertNil(CronExpression("-1 * * * *"))   // negative
    }

    func testInvalidExpressionBadHour() {
        XCTAssertNil(CronExpression("0 24 * * *"))   // hour 24 out of range
    }

    func testInvalidExpressionBadMonth() {
        XCTAssertNil(CronExpression("0 0 * 13 *"))   // month 13
        XCTAssertNil(CronExpression("0 0 * 0 *"))    // month 0
    }

    func testInvalidExpressionBadDayOfMonth() {
        XCTAssertNil(CronExpression("0 0 32 * *"))   // day 32
        XCTAssertNil(CronExpression("0 0 0 * *"))    // day 0
    }

    func testInvalidExpressionBadStep() {
        XCTAssertNil(CronExpression("*/0 * * * *"))  // step 0
        XCTAssertNil(CronExpression("*/abc * * * *"))
    }

    func testInvalidExpressionBadRange() {
        XCTAssertNil(CronExpression("5-2 * * * *"))  // inverted range
    }

    func testInvalidExpressionEmptyString() {
        XCTAssertNil(CronExpression(""))
    }

    func testInvalidExpressionGarbageText() {
        XCTAssertNil(CronExpression("hello world foo bar baz"))
    }

    // MARK: - nextFireDate with fixed reference dates

    func testNextFireDateFirstOfMonth() {
        // "0 0 1 * *" = midnight on the 1st of every month
        let cron = CronExpression("0 0 1 * *")!
        let cal = utcCalendar
        // After Jan 15 → should be Feb 1 at midnight
        let after = makeDate(year: 2025, month: 1, day: 15, hour: 12, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        XCTAssertEqual(comps.year, 2025)
        XCTAssertEqual(comps.month, 2)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
    }

    func testNextFireDateSpecificMonthAndDay() {
        // "0 12 25 12 *" = noon on Dec 25
        let cron = CronExpression("0 12 25 12 *")!
        let cal = utcCalendar
        // After Dec 26 2025 → should be Dec 25 2026
        let after = makeDate(year: 2025, month: 12, day: 26, hour: 0, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 25)
        XCTAssertEqual(comps.hour, 12)
        XCTAssertEqual(comps.minute, 0)
    }

    func testNextFireDateEveryMinute() {
        // "* * * * *" = every minute
        let cron = CronExpression("* * * * *")!
        let cal = utcCalendar
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 10, minute: 30)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.minute, 31)
    }

    func testNextFireDateYearRollover() {
        // "0 0 1 1 *" = midnight Jan 1
        let cron = CronExpression("0 0 1 1 *")!
        let cal = utcCalendar
        // After Jan 2, 2025 → should be Jan 1, 2026
        let after = makeDate(year: 2025, month: 1, day: 2, hour: 0, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.year, .month, .day], from: next!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
    }

    func testNextFireDateListExpression() {
        // "0 9,17 * * *" = 9:00 and 17:00 daily
        let cron = CronExpression("0 9,17 * * *")!
        let cal = utcCalendar
        // After 10:00 → should be 17:00 same day
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 10, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.day, .hour, .minute], from: next!)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 17)
        XCTAssertEqual(comps.minute, 0)
    }

    func testNextFireDateRangeWithStep() {
        // "0 8-17/3 * * *" = hours 8, 11, 14, 17
        let cron = CronExpression("0 8-17/3 * * *")!
        XCTAssertEqual(cron.hours, Set([8, 11, 14, 17]))
        let cal = utcCalendar
        // After 12:00 → should be 14:00
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 12, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.minute, 0)
    }

    func testNextFireDateSunday7Alias() {
        // "0 9 * * 7" = Sunday (7 is alias for 0=Sunday)
        let cron = CronExpression("0 9 * * 7")!
        // Calendar weekday 1 = Sunday
        XCTAssertEqual(cron.daysOfWeek, Set([1]))
        let cal = utcCalendar
        // 2025-06-15 is Sunday. After 8:00 AM → should be 9:00 AM same day
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 8, minute: 0)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.day, .weekday, .hour], from: next!)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.weekday, 1) // Sunday
        XCTAssertEqual(comps.hour, 9)
    }

    // MARK: - DST spring-forward handling

    func testDSTSpringForwardSkipsNonexistentTime() {
        // In America/New_York, March 9, 2025 at 2:00 AM → clocks jump to 3:00 AM
        // A cron job at "30 2 * * *" should still fire on that day
        guard let eastern = TimeZone(identifier: "America/New_York") else {
            XCTFail("Could not create Eastern timezone")
            return
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern

        let cron = CronExpression("30 2 * * *")!
        // After March 8 at 3:00 AM
        let after = makeDate(year: 2025, month: 3, day: 8, hour: 3, minute: 0, timeZone: eastern)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next, "Should return a date even during DST spring-forward")

        let comps = cal.dateComponents([.year, .month, .day], from: next!)
        XCTAssertEqual(comps.year, 2025)
        XCTAssertEqual(comps.month, 3)
        // The date should be March 9 (DST day) or March 10 depending on how Calendar resolves it
        // Key assertion: the function does NOT return nil for a DST gap
        XCTAssertTrue(comps.day! >= 9 && comps.day! <= 10,
                       "Should fire on or near the DST transition day, got day \(comps.day!)")
    }

    func testDSTSpringForwardDoesNotAffectNonGapTimes() {
        // A cron job at "0 9 * * *" (9:00 AM) should not be affected by spring-forward at 2 AM
        guard let eastern = TimeZone(identifier: "America/New_York") else {
            XCTFail("Could not create Eastern timezone")
            return
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern

        let cron = CronExpression("0 9 * * *")!
        // After March 8 at 10:00 AM → next should be March 9 at 9:00 AM (DST day, but 9 AM exists)
        let after = makeDate(year: 2025, month: 3, day: 8, hour: 10, minute: 0, timeZone: eastern)
        let next = cron.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.month, .day, .hour, .minute], from: next!)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 9)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
    }

    // MARK: - ScheduledTask convenience

    func testScheduledTaskNextFireDate() {
        let task = ScheduledTask(
            name: "test",
            cronExpression: "0 12 * * *",
            command: "echo hello"
        )
        let cal = utcCalendar
        let after = makeDate(year: 2025, month: 6, day: 15, hour: 10, minute: 0)
        // Use parsedCron directly since convenience method uses Calendar.current
        let next = task.parsedCron?.nextFireDate(after: after, calendar: cal)
        XCTAssertNotNil(next)
        let comps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(comps.hour, 12)
        XCTAssertEqual(comps.minute, 0)
    }

    func testScheduledTaskInvalidCronReturnsNil() {
        let task = ScheduledTask(
            name: "bad",
            cronExpression: "not a cron",
            command: "echo"
        )
        XCTAssertNil(task.parsedCron)
        XCTAssertNil(task.nextFireDate(after: Date()))
    }
}
