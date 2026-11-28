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

/// `text[a..b]` as a number of ASCII digits; None when out of range.
fn field(text: &str, a: usize, b: usize) -> Option<i64> {
    digits(text.get(a..b)?)
}

/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` or with a `±HH:MM` offset; None for anything else.
pub fn parse_rfc3339(text: &str) -> Option<f64> {
    if !text.is_ascii() || text.len() < 20 {
        return None;
    }
    let b = text.as_bytes();
    let at = |i: usize| b.get(i).copied();
    if at(4) != Some(b'-')
        || at(7) != Some(b'-')
        || at(10) != Some(b'T')
        || at(13) != Some(b':')
        || at(16) != Some(b':')
    {
        return None;
    }
    let year = field(text, 0, 4)?;
    let month = field(text, 5, 7)?;
    let day = field(text, 8, 10)?;
    let hour = field(text, 11, 13)?;
    let minute = field(text, 14, 16)?;
    let second = field(text, 17, 19)?;
    if !(1..=12).contains(&month)
        || day < 1
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let mut rest = text.get(19..)?;
    let mut fraction = 0.0;
    if let Some(after) = rest.strip_prefix('.') {
        let end = after.find(|c: char| !c.is_ascii_digit()).unwrap_or(after.len());
        if end == 0 {
            return None;
        }
        fraction = format!("0.{}", after.get(..end)?).parse().ok()?;
        rest = after.get(end..)?;
    }
    let offset = match rest {
        "Z" => 0,
        _ if rest.len() == 6 && rest.as_bytes().get(3) == Some(&b':') => {
            let sign = match rest.as_bytes().first() {
                Some(b'+') => 1,
                Some(b'-') => -1,
                _ => return None,
            };
            let h = field(rest, 1, 3)?;
            let m = field(rest, 4, 6)?;
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
