/// Parses an RFC 3339 / ISO 8601 timestamp (`2026-10-01T10:00:00.123Z`,
/// offsets `+02:00`, a space instead of `T`) to Unix milliseconds.
pub fn parse_rfc3339_ms(text: &str) -> Option<i64> {
    let bytes = text.trim().as_bytes();
    if bytes.len() < 19
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return None;
    }
    if !matches!(bytes[10], b'T' | b't' | b' ') {
        return None;
    }
    let num = |range: std::ops::Range<usize>| -> Option<i64> {
        let digits = bytes.get(range)?;
        if !digits.iter().all(u8::is_ascii_digit) {
            return None;
        }
        std::str::from_utf8(digits).ok()?.parse().ok()
    };
    let (year, month, day) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hour, minute, second) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let mut rest = &bytes[19..];
    let mut millis = 0i64;
    if let Some((b'.', frac)) = rest.split_first() {
        let len = frac.iter().take_while(|byte| byte.is_ascii_digit()).count();
        if len == 0 {
            return None;
        }
        for (index, digit) in frac[..len.min(3)].iter().enumerate() {
            millis += i64::from(digit - b'0') * [100, 10, 1][index];
        }
        rest = &frac[len..];
    }
    let offset_minutes = match rest {
        [] | [b'Z' | b'z'] => 0,
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] | [sign @ (b'+' | b'-'), h1, h2, m1, m2] => {
            let digits = [*h1, *h2, *m1, *m2];
            if !digits.iter().all(u8::is_ascii_digit) {
                return None;
            }
            let value = |a: u8, b: u8| i64::from(a - b'0') * 10 + i64::from(b - b'0');
            let minutes = value(digits[0], digits[1]) * 60 + value(digits[2], digits[3]);
            if *sign == b'-' { -minutes } else { minutes }
        }
        _ => return None,
    };
    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset_minutes * 60;
    Some(seconds * 1_000 + millis)
}

/// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::parse_rfc3339_ms;

    #[test]
    fn parses_utc_offsets_and_fractions() {
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339_ms("2026-10-01T10:00:00.123Z"), Some(1_790_848_800_123));
        assert_eq!(parse_rfc3339_ms("2026-10-01T12:00:00+02:00"), Some(1_790_848_800_000));
        assert_eq!(parse_rfc3339_ms("2026-10-01 10:00:00"), Some(1_790_848_800_000));
        assert_eq!(parse_rfc3339_ms("not a time"), None);
        assert_eq!(parse_rfc3339_ms("2026-13-01T10:00:00Z"), None);
    }
}
