//! A place on Earth for the sun's position (Swift `BackdropLocation`): the setting's
//! `"lat,lon"` text, or the time zone's city from `zone.tab`.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Degrees north and east.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Location {
    pub latitude: f64,
    pub longitude: f64,
}

impl Location {
    /// Reads `"lat,lon"` (spaces around either allowed); nil for anything else or out of range.
    pub fn parse(text: &str) -> Option<Self> {
        let parts: Vec<&str> = text.split(',').map(|p| p.trim_matches(is_space)).collect();
        let [latitude, longitude] = parts.as_slice() else { return None };
        let (latitude, longitude) = (number(latitude)?, number(longitude)?);
        (latitude.is_finite()
            && longitude.is_finite()
            && latitude.abs() <= 90.0
            && longitude.abs() <= 180.0)
            .then_some(Self { latitude, longitude })
    }

    /// The location of a time zone: its `zone.tab` city, else the equator at the longitude its
    /// offset implies (15 degrees an hour).
    pub fn of(identifier: &str, seconds_from_gmt: i32, zones: &BTreeMap<String, Location>) -> Self {
        zones
            .get(identifier)
            .copied()
            .unwrap_or(Self { latitude: 0.0, longitude: f64::from(seconds_from_gmt) / 240.0 })
    }
}

/// `CharacterSet.whitespaces`: spaces and tabs, not line breaks.
fn is_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(c, '\n' | '\r' | '\u{0b}' | '\u{0c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Swift `Double(String)` for the decimal forms it reads (hex floats aside).
fn number(text: &str) -> Option<f64> {
    if text.is_empty() || text.starts_with(char::is_whitespace) {
        return None;
    }
    text.parse().ok()
}

/// Reads `zone.tab`: zone id to its city's coordinates; comment lines and short rows skipped.
pub fn parse_zone_table(text: &str) -> BTreeMap<String, Location> {
    let mut zones = BTreeMap::new();
    for line in text.split('\n').filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 3 {
            continue;
        }
        if let Some(location) = coordinates(fields[1]) {
            zones.insert(fields[2].to_string(), location);
        }
    }
    zones
}

/// `zone.tab`'s ISO 6709 coordinates: `+DDMM+DDDMM` or `+DDMMSS+DDDMMSS`.
pub fn coordinates(text: &str) -> Option<Location> {
    let split = text.char_indices().skip(1).find(|&(_, c)| c == '+' || c == '-')?.0;
    let latitude = angle(&text[..split], 2)?;
    let longitude = angle(&text[split..], 3)?;
    Some(Location { latitude, longitude })
}

fn angle(text: &str, degree_digits: usize) -> Option<f64> {
    let mut chars = text.chars();
    let sign = chars.next()?;
    if sign != '+' && sign != '-' {
        return None;
    }
    let digits: Vec<char> = chars.collect();
    if !(digits.len() == degree_digits + 2 || digits.len() == degree_digits + 4)
        || !digits.iter().all(char::is_ascii)
    {
        return None;
    }
    let part = |range: std::ops::Range<usize>| number(&digits[range].iter().collect::<String>());
    let degrees = part(0..degree_digits)?;
    let minutes = part(degree_digits..degree_digits + 2)?;
    let seconds = if digits.len() > degree_digits + 2 {
        part(degree_digits + 2..digits.len()).unwrap_or(0.0)
    } else {
        0.0
    };
    let value = degrees + minutes / 60.0 + seconds / 3_600.0;
    Some(if sign == '-' { -value } else { value })
}
