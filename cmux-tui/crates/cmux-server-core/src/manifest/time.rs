//! RFC 3339 timestamps in UTC (`YYYY-MM-DDTHH:MM:SS[.fff]Z`) to Unix ms.

fn digits(s: &str) -> Option<u64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

/// Days from 1970-01-01 to `y-m-d` in the proleptic Gregorian calendar.
fn days_from_civil(y: i64, m: u64, d: u64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy as i64;
    era * 146_097 + doe - 719_468
}

fn days_in_month(y: u64, m: u64) -> u64 {
    match m {
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Parses a UTC timestamp. Offsets other than `Z` are refused so a signed
/// expiry has exactly one reading. Years before 1970 are refused.
pub fn parse_rfc3339_utc_ms(s: &str) -> Option<u64> {
    let s = s.strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-');
    let (y, mo, da) = (d.next()?, d.next()?, d.next()?);
    if d.next().is_some() || y.len() != 4 || mo.len() != 2 || da.len() != 2 {
        return None;
    }
    let (time, frac) = match time.split_once('.') {
        Some((t, f)) if (1..=9).contains(&f.len()) => (t, Some(f)),
        Some(_) => return None,
        None => (time, None),
    };
    let mut t = time.split(':');
    let (h, mi, se) = (t.next()?, t.next()?, t.next()?);
    if t.next().is_some() || h.len() != 2 || mi.len() != 2 || se.len() != 2 {
        return None;
    }
    let (y, mo, da) = (digits(y)?, digits(mo)?, digits(da)?);
    let (h, mi, se) = (digits(h)?, digits(mi)?, digits(se)?);
    if y < 1970 || !(1..=12).contains(&mo) || da == 0 || da > days_in_month(y, mo) || h > 23 || mi > 59 || se > 59 {
        return None;
    }
    let ms = match frac {
        Some(f) => {
            let padded = format!("{f:0<9}");
            digits(&padded)? / 1_000_000
        }
        None => 0,
    };
    let days = days_from_civil(y as i64, mo, da) as u64;
    Some(((days * 86_400 + h * 3600 + mi * 60 + se) * 1000) + ms)
}
