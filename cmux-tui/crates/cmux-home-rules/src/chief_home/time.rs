//! The ISO 8601 dates the Chief moves read and write (Foundation's `ISO8601DateFormatter`), and the
//! JSON text Foundation's `JSONSerialization` writes for their records.

use serde_json::Value;

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date of days since 1970-01-01.
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (if month <= 2 { yoe + era * 400 + 1 } else { yoe + era * 400 }, month, day)
}

fn digits(text: &[u8], count: usize) -> Option<i64> {
    let part = text.get(..count)?;
    part.iter()
        .all(u8::is_ascii_digit)
        .then(|| part.iter().fold(0, |n, d| n * 10 + i64::from(d - b'0')))
}

/// An internet date-time (`2026-11-25T12:00:00Z`, `+hh:mm` offsets), with fractional seconds when
/// `fractional` (which then must be there, as Foundation's option requires).
fn parse_with(text: &str, fractional: bool) -> Option<f64> {
    let b = text.as_bytes();
    let year = digits(b, 4)?;
    let month = digits(b.get(5..)?, 2)?;
    let day = digits(b.get(8..)?, 2)?;
    let hour = digits(b.get(11..)?, 2)?;
    let minute = digits(b.get(14..)?, 2)?;
    let second = digits(b.get(17..)?, 2)?;
    let at = |index: usize| b.get(index).copied();
    if at(4) != Some(b'-')
        || at(7) != Some(b'-')
        || !matches!(at(10), Some(b'T' | b't'))
        || at(13) != Some(b':')
        || at(16) != Some(b':')
    {
        return None;
    }
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let mut rest = b.get(19..)?;
    let mut fraction = 0.0;
    if fractional {
        let digits = rest.strip_prefix(b".")?;
        let count = digits.iter().take_while(|c| c.is_ascii_digit()).count();
        if count == 0 {
            return None;
        }
        let (whole, after) = digits.split_at_checked(count)?;
        let text = std::str::from_utf8(whole).ok()?;
        fraction = format!("0.{text}").parse::<f64>().ok()?;
        rest = after;
    }
    let offset = match rest {
        [b'Z' | b'z'] => 0,
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
            let hours = digits(&[*h1, *h2], 2)?;
            let minutes = digits(&[*m1, *m2], 2)?;
            let total = hours * 3600 + minutes * 60;
            if *sign == b'-' { -total } else { total }
        }
        _ => return None,
    };
    let seconds =
        days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset;
    Some(seconds as f64 + fraction)
}

/// `ChiefMigrationPlan.time`: seconds since 1970 of a date with or without fractional seconds; 0 when
/// it is neither.
pub fn time(text: &str) -> f64 {
    parse_with(text, true).or_else(|| parse_with(text, false)).unwrap_or(0.0)
}

fn parts(seconds: i64) -> (i64, i64, i64, i64, i64, i64) {
    let (year, month, day) = civil_from_days(seconds.div_euclid(86_400));
    let rest = seconds.rem_euclid(86_400);
    (year, month, day, rest / 3600, rest % 3600 / 60, rest % 60)
}

/// `ISO8601DateFormatter().string(from:)`: `2026-11-25T12:00:00Z`.
pub fn internet(seconds: f64) -> String {
    let (y, mo, d, h, mi, s) = parts(seconds.floor() as i64);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// `ChiefAdoption`'s backup stamp: the basic format with no separators, `20261125T120000Z`.
pub fn basic_stamp(seconds: f64) -> String {
    let (y, mo, d, h, mi, s) = parts(seconds.floor() as i64);
    format!("{y:04}{mo:02}{d:02}T{h:02}{mi:02}{s:02}Z")
}

/// `ChiefMigrationPlan.localDate`'s formatting: milliseconds, in the zone `utc_offset` seconds east
/// (`Z` at 0).
pub fn fractional_local(seconds: f64, utc_offset: i64) -> String {
    // Microseconds first so a date read back as 0.123 does not print 122.
    let micros = (seconds * 1_000_000.0).round() as i64;
    let millis = micros.div_euclid(1000);
    let local = millis.div_euclid(1000) + utc_offset;
    let (y, mo, d, h, mi, s) = parts(local);
    let ms = millis.rem_euclid(1000);
    let zone = if utc_offset == 0 {
        "Z".to_owned()
    } else {
        let sign = if utc_offset < 0 { '-' } else { '+' };
        let abs = utc_offset.abs();
        format!("{sign}{:02}:{:02}", abs / 3600, abs % 3600 / 60)
    };
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{ms:03}{zone}")
}

/// A JSON string as `JSONSerialization` writes it; `escape_slashes` unless `.withoutEscapingSlashes`.
pub fn string(text: &str, escape_slashes: bool) -> String {
    let json = serde_json::to_string(text).unwrap_or_default();
    if escape_slashes { json.replace('/', "\\/") } else { json }
}

fn pretty_into(value: &Value, indent: usize, out: &mut String) {
    let pad = "  ".repeat(indent + 1);
    let end = "  ".repeat(indent);
    match value {
        Value::String(text) => out.push_str(&string(text, true)),
        Value::Array(items) => {
            out.push_str("[\n");
            if items.is_empty() {
                out.push('\n');
            }
            for (index, item) in items.iter().enumerate() {
                out.push_str(&pad);
                pretty_into(item, indent + 1, out);
                out.push_str(if index + 1 < items.len() { ",\n" } else { "\n" });
            }
            out.push_str(&end);
            out.push(']');
        }
        Value::Object(fields) => {
            out.push_str("{\n");
            if fields.is_empty() {
                out.push('\n');
            }
            let mut keys: Vec<&String> = fields.keys().collect();
            keys.sort();
            for (index, key) in keys.iter().enumerate() {
                out.push_str(&pad);
                out.push_str(&string(key, true));
                out.push_str(" : ");
                pretty_into(&fields[*key], indent + 1, out);
                out.push_str(if index + 1 < keys.len() { ",\n" } else { "\n" });
            }
            out.push_str(&end);
            out.push('}');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// `JSONSerialization` with `[.prettyPrinted, .sortedKeys]`: two-space indents, `" : "`, escaped
/// slashes, and Darwin's blank line inside an empty array or object.
pub fn pretty_sorted(value: &Value) -> String {
    let mut out = String::new();
    pretty_into(value, 0, &mut out);
    out
}
