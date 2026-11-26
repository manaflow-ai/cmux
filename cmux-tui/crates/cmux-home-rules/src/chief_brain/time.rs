//! `ISO8601DateFormatter` with `.withInternetDateTime` (and `.withFractionalSeconds`), as
//! `ChiefReplyWatchdog.date` reads a message's `createdAt`: seconds since 1970.

fn digits(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

/// Days from 1970-01-01 to the civil date (Howard Hinnant's `days_from_civil`).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        _ => 28,
    }
}

/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` or with a `±HH:MM` offset; None for anything else.
pub fn parse_rfc3339(text: &str) -> Option<f64> {
    if !text.is_ascii() || text.len() < 20 {
        return None;
    }
    let b = text.as_bytes();
    if b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let year = digits(&text[0..4])?;
    let month = digits(&text[5..7])?;
    let day = digits(&text[8..10])?;
    let hour = digits(&text[11..13])?;
    let minute = digits(&text[14..16])?;
    let second = digits(&text[17..19])?;
    if !(1..=12).contains(&month)
        || day < 1
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let mut rest = &text[19..];
    let mut fraction = 0.0;
    if let Some(after) = rest.strip_prefix('.') {
        let end = after.find(|c: char| !c.is_ascii_digit()).unwrap_or(after.len());
        if end == 0 {
            return None;
        }
        fraction = format!("0.{}", &after[..end]).parse().ok()?;
        rest = &after[end..];
    }
    let offset = match rest {
        "Z" => 0,
        _ if rest.len() == 6 && rest.as_bytes()[3] == b':' => {
            let sign = match rest.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let h = digits(&rest[1..3])?;
            let m = digits(&rest[4..6])?;
            if h > 23 || m > 59 {
                return None;
            }
            sign * (h * 3600 + m * 60)
        }
        _ => return None,
    };
    let secs =
        days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset;
    Some(secs as f64 + fraction)
}
