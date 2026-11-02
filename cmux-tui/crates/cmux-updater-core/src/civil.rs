//! Dates as Swift's `Date` carries them: seconds since 1970-01-01 UTC.

const MONTHS: [&str; 12] =
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const WEEKDAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const SECONDS_PER_DAY: i64 = 86_400;

/// Days from 1970-01-01 to `year-month-day` (proleptic Gregorian; Howard
/// Hinnant's `days_from_civil`).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year.saturating_sub(1) } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let month_index = if month > 2 { month.saturating_sub(3) } else { month.saturating_add(9) };
    let day_of_year =
        (153i64.saturating_mul(month_index).saturating_add(2)) / 5 + day.saturating_sub(1);
    let day_of_era = year_of_era
        .saturating_mul(365)
        .saturating_add(year_of_era / 4)
        .saturating_sub(year_of_era / 100)
        .saturating_add(day_of_year);
    era.saturating_mul(146_097).saturating_add(day_of_era).saturating_sub(719_468)
}

/// `(year, month, day)` of a day count from 1970-01-01.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days.saturating_add(719_468);
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era = (day_of_era
        .saturating_sub(day_of_era / 1460)
        .saturating_add(day_of_era / 36_524)
        .saturating_sub(day_of_era / 146_096))
        / 365;
    let day_of_year = day_of_era.saturating_sub(
        year_of_era
            .saturating_mul(365)
            .saturating_add(year_of_era / 4)
            .saturating_sub(year_of_era / 100),
    );
    let month_index = (day_of_year.saturating_mul(5).saturating_add(2)) / 153;
    let day = day_of_year
        .saturating_sub((153i64.saturating_mul(month_index).saturating_add(2)) / 5)
        .saturating_add(1);
    let month = if month_index < 10 {
        month_index.saturating_add(3)
    } else {
        month_index.saturating_sub(9)
    };
    let year = year_of_era.saturating_add(era.saturating_mul(400));
    (if month <= 2 { year.saturating_add(1) } else { year }, month, day)
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if is_leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

fn number(text: &str, digits: std::ops::RangeInclusive<usize>) -> Option<i64> {
    if !digits.contains(&text.len()) || !text.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// An appcast `<pubDate>` in the form the feed writes it (DateFormatter
/// `EEE, dd MMM yyyy HH:mm:ss Z`, `en_US_POSIX`): "Sat, 10 Oct 2026 03:05:21 +0000".
/// Names match without case; the weekday is not checked against the date.
pub fn parse_rfc822(text: &str) -> Option<f64> {
    let mut fields = text.split(' ');
    let weekday = fields.next()?.strip_suffix(',')?.to_ascii_lowercase();
    if !WEEKDAYS.contains(&weekday.as_str()) {
        return None;
    }
    let day = number(fields.next()?, 1..=2)?;
    let month_name = fields.next()?.to_ascii_lowercase();
    let month = MONTHS.iter().position(|name| *name == month_name)?;
    let month = i64::try_from(month).ok()?.saturating_add(1);
    let year = number(fields.next()?, 4..=4)?;
    let mut clock = fields.next()?.split(':');
    let hour = number(clock.next()?, 2..=2)?;
    let minute = number(clock.next()?, 2..=2)?;
    let second = number(clock.next()?, 2..=2)?;
    if clock.next().is_some() {
        return None;
    }
    let zone = fields.next()?;
    if fields.next().is_some() {
        return None;
    }
    let (sign, offset) = match zone.chars().next()? {
        '+' => (1, zone.get(1..)?),
        '-' => (-1, zone.get(1..)?),
        _ => return None,
    };
    let offset_hours = number(offset.get(0..2)?, 2..=2)?;
    let offset_minutes = number(offset.get(2..)?, 2..=2)?;
    if !(1..=days_in_month(year, month)).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
        || offset_minutes > 59
    {
        return None;
    }
    let local = days_from_civil(year, month, day)
        .saturating_mul(SECONDS_PER_DAY)
        .saturating_add(hour.saturating_mul(3600))
        .saturating_add(minute.saturating_mul(60))
        .saturating_add(second);
    let offset =
        offset_hours.saturating_mul(3600).saturating_add(offset_minutes.saturating_mul(60));
    let utc = if sign > 0 { local.saturating_sub(offset) } else { local.saturating_add(offset) };
    #[allow(
        clippy::cast_precision_loss,
        reason = "seconds since 1970 of a 4-digit year fit f64 exactly"
    )]
    let utc = utc as f64;
    Some(utc)
}

/// `YYYY-MM-DD` in UTC (`Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()`),
/// as `notes/index.json` writes a build's day.
pub fn utc_day(seconds: f64) -> String {
    let days = (seconds / 86_400.0).floor();
    #[allow(
        clippy::cast_possible_truncation,
        reason = "a saturating float-to-int cast; dates are far inside i64"
    )]
    let days = days as i64;
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}")
}
