//! Swift `String` behaviors the journal's rules were written against, so the Rust rules give the
//! same text: `utf8Prefix`, `trimmingCharacters(in: .whitespaces)`, `split(separator: "\n")` and
//! the ISO 8601 dates the journal reads and writes.

use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_segmentation::UnicodeSegmentation;

/// `text` cut to at most `bytes` UTF-8 bytes at a character boundary, with "…" appended when cut.
pub fn utf8_prefix(text: &str, bytes: usize) -> String {
    if text.len() <= bytes {
        return text.to_owned();
    }
    let mut end = 0;
    for (index, _) in text.grapheme_indices(true) {
        if index > bytes {
            break;
        }
        end = index;
    }
    format!("{}…", text.get(..end).unwrap_or_default())
}

/// Swift's `CharacterSet.whitespaces`: tab and the space separators (Zs).
pub fn is_swift_whitespace(character: char) -> bool {
    character == '\t' || get_general_category(character) == GeneralCategory::SpaceSeparator
}

/// `trimmingCharacters(in: .whitespaces)`.
pub fn trim_whitespaces(text: &str) -> &str {
    text.trim_matches(is_swift_whitespace)
}

/// Swift's `CharacterSet.alphanumerics`: letters, marks and numbers.
pub fn is_swift_alphanumeric(character: char) -> bool {
    use GeneralCategory as G;
    matches!(
        get_general_category(character),
        G::UppercaseLetter
            | G::LowercaseLetter
            | G::TitlecaseLetter
            | G::ModifierLetter
            | G::OtherLetter
            | G::NonspacingMark
            | G::SpacingMark
            | G::EnclosingMark
            | G::DecimalNumber
            | G::LetterNumber
            | G::OtherNumber
    )
}

/// `text.split(separator: "\n", omittingEmptySubsequences:)`: a "\n" right after "\r" is one
/// character with it ("\r\n"), so it does not separate.
pub fn split_lines(text: &str, omit_empty: bool) -> Vec<&str> {
    let bytes = text.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    for (index, &byte) in bytes.iter().enumerate() {
        if byte == b'\n' && (index == 0 || bytes.get(index - 1) != Some(&b'\r')) {
            lines.push(text.get(start..index).unwrap_or_default());
            start = index + 1;
        }
    }
    lines.push(text.get(start..).unwrap_or_default());
    if omit_empty {
        lines.retain(|line| !line.is_empty());
    }
    lines
}

/// The byte index just past the first "\n" that separates lines (see [`split_lines`]).
pub fn after_first_line_break(text: &str) -> Option<usize> {
    let bytes = text.as_bytes();
    bytes
        .iter()
        .enumerate()
        .find(|&(index, &byte)| {
            byte == b'\n' && (index == 0 || bytes.get(index - 1) != Some(&b'\r'))
        })
        .map(|(index, _)| index + 1)
}

/// Swift's `split(separator: ":")` (empty pieces dropped).
pub fn split_colon(text: &str) -> Vec<&str> {
    text.split(':').filter(|part| !part.is_empty()).collect()
}

/// Days from 1970-01-01 to the proleptic Gregorian date.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let days = days + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// Seconds since 1970 of `YYYY-MM-DDTHH:MM:SS[.fff…]Z` (ISO8601DateFormatter, internet date
/// time with or without fractional seconds, kept to the millisecond). None when it is not one.
pub fn parse_iso8601(text: &str) -> Option<f64> {
    let bytes = text.as_bytes();
    let digits = |range: std::ops::Range<usize>| -> Option<i64> {
        let slice = bytes.get(range)?;
        if slice.is_empty() || !slice.iter().all(u8::is_ascii_digit) {
            return None;
        }
        Some(slice.iter().fold(0_i64, |value, digit| value * 10 + i64::from(digit - b'0')))
    };
    if bytes.len() < 20
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
        || bytes.last() != Some(&b'Z')
    {
        return None;
    }
    let (year, month, day) = (digits(0..4)?, digits(5..7)?, digits(8..10)?);
    let (hour, minute, second) = (digits(11..13)?, digits(14..16)?, digits(17..19)?);
    let millis = match bytes.len() {
        20 => 0,
        _ => {
            if bytes.get(19) != Some(&b'.') {
                return None;
            }
            let fraction = bytes.get(20..bytes.len() - 1).unwrap_or_default();
            if fraction.is_empty() || !fraction.iter().all(u8::is_ascii_digit) {
                return None;
            }
            (0..3).fold(0_i64, |value, index| {
                value * 10 + fraction.get(index).map_or(0, |digit| i64::from(digit - b'0'))
            })
        }
    };
    let month_days =
        [31, if is_leap(year) { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=12).contains(&month)
        || day < 1
        || month_days.get((month - 1) as usize).is_none_or(|&days| day > days)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let seconds = days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second;
    Some(seconds as f64 + millis as f64 / 1000.0)
}

/// `ISO8601DateFormatter().string(from:)` of a time in milliseconds: `YYYY-MM-DDTHH:MM:SSZ`, UTC.
pub fn format_iso8601_ms(ms: i64) -> String {
    let seconds = ms.div_euclid(1000);
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let of_day = seconds.rem_euclid(86_400);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        of_day / 3600,
        of_day % 3600 / 60,
        of_day % 60
    )
}

/// Swift's `Int64((seconds * 1000).rounded())`.
pub fn rounded_ms(seconds: f64) -> i64 {
    (seconds * 1000.0).round() as i64
}

/// Swift's `Int64((seconds * 1000).rounded(.up))`.
pub fn ceil_ms(seconds: f64) -> i64 {
    (seconds * 1000.0).ceil() as i64
}
