//! The one clock of a recording: wall-clock microseconds since the Unix epoch.
//!
//! Every source is put on it: the sampler reads `SystemTime`, `log stream`
//! prints a local time with its offset (`2026-10-23 04:55:41.243635-0700`),
//! and the agent page ring writes ISO 8601 UTC (`2026-11-07T09:01:02.345Z`).
//! std has no calendar, so the two conversions are here (Howard Hinnant's
//! days-from-civil, exact for every proleptic Gregorian date).

use std::time::{SystemTime, UNIX_EPOCH};

/// Now, in microseconds since the Unix epoch.
pub fn now_us() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(since) => i64::try_from(since.as_micros()).unwrap_or(i64::MAX),
        Err(before) => -i64::try_from(before.duration().as_micros()).unwrap_or(i64::MAX),
    }
}

/// Days from 1970-01-01 to the civil date `year-month-day`.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// The civil date (year, month, day) `days` after 1970-01-01.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let days = days + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 { shifted_month + 3 } else { shifted_month - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// `YYYY-MM-DD[T ]HH:MM:SS[.fraction](Z|±HHMM|±HH:MM)` in microseconds since
/// the epoch: the `log stream` timestamp and ISO 8601. `None` for anything else.
pub fn parse_timestamp(text: &str) -> Option<i64> {
    let text = text.trim();
    let bytes = text.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[13] != b':' {
        return None;
    }
    if !matches!(bytes[10], b'T' | b' ') || bytes[16] != b':' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let part = text.get(range)?;
        part.bytes().all(|b| b.is_ascii_digit()).then(|| part.parse().ok())?
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 {
        return None;
    }
    let mut rest = &text[19..];
    let mut micros = 0i64;
    if let Some(fraction) = rest.strip_prefix('.') {
        let digits = fraction.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        let kept = &fraction[..digits.min(6)];
        micros = kept.parse::<i64>().ok()? * 10i64.pow(6 - kept.len() as u32);
        rest = &fraction[digits..];
    }
    let offset_s = match rest {
        "Z" | "z" => 0,
        _ => {
            let sign = match rest.as_bytes().first()? {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let digits: String = rest.get(1..)?.chars().filter(|c| *c != ':').collect();
            if digits.len() != 4 || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let hours: i64 = digits[..2].parse().ok()?;
            let minutes: i64 = digits[2..].parse().ok()?;
            sign * (hours * 3600 + minutes * 60)
        }
    };
    let seconds =
        days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset_s;
    Some(seconds * 1_000_000 + micros)
}

/// `us` as ISO 8601 UTC with milliseconds (`2026-11-07T09:01:02.345Z`).
pub fn iso_utc(us: i64) -> String {
    let (seconds, micros) = (us.div_euclid(1_000_000), us.rem_euclid(1_000_000));
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let of_day = seconds.rem_euclid(86_400);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        of_day / 3600,
        of_day / 60 % 60,
        of_day % 60,
        micros / 1000
    )
}

/// `us` as a compact UTC stamp for a folder name (`20261107T090102Z`).
pub fn utc_stamp(us: i64) -> String {
    let seconds = us.div_euclid(1_000_000);
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let of_day = seconds.rem_euclid(86_400);
    format!(
        "{year:04}{month:02}{day:02}T{:02}{:02}{:02}Z",
        of_day / 3600,
        of_day / 60 % 60,
        of_day % 60
    )
}
