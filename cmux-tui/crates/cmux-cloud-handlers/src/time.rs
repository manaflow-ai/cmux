//! UTC timestamps as the app has always written them: ISO 8601 in result
//! fields (`2026-11-06T12:00:00Z`, whole seconds), and a date's plain
//! description in answer text (`2026-11-06 12:00:00 +0000`).

/// `(year, month, day, hour, minute, second)` of `unix` seconds, in UTC.
#[allow(
    clippy::arithmetic_side_effects,
    clippy::cast_possible_truncation,
    reason = "days of an i64 of seconds stay far inside i64, and each part is in range of u32 by construction"
)]
fn civil(unix: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = unix.div_euclid(86_400);
    let seconds = unix.rem_euclid(86_400);
    // Howard Hinnant's days-to-civil.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    let (hour, minute, second) =
        ((seconds / 3_600) as u32, (seconds / 60 % 60) as u32, (seconds % 60) as u32);
    (year, month, day, hour, minute, second)
}

/// `unix` seconds (fractions dropped) as ISO 8601 in UTC: `2026-11-06T12:00:00Z`.
#[allow(
    clippy::cast_possible_truncation,
    reason = "a date's seconds; an out-of-range value saturates, as a date can't be that far"
)]
pub fn iso8601(unix: f64) -> String {
    let (y, mo, d, h, mi, s) = civil(unix.floor() as i64);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// `unix` seconds as a date's plain description: `2026-11-06 12:00:00 +0000`.
pub fn described(unix: i64) -> String {
    let (y, mo, d, h, mi, s) = civil(unix);
    format!("{y:04}-{mo:02}-{d:02} {h:02}:{mi:02}:{s:02} +0000")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_epoch_and_a_leap_day() {
        assert_eq!(iso8601(0.0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(1_709_208_000.9), "2024-02-29T12:00:00Z");
        assert_eq!(described(1_700_000_000), "2023-11-14 22:13:20 +0000");
        assert_eq!(iso8601(-1.0), "1969-12-31T23:59:59Z");
    }
}
