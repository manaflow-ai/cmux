//! A background that changes with the time of day (Swift `BackdropTimeOfDay`): keys are wall
//! clock times (`"07:00"`) or sun events with an offset (`"sunset-30m"`), values are the picture
//! shown from then on.

use super::location::Location;
use super::sun::{SunEvents, sun_events};
use super::zone::Zone;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A sun event a key can name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SunEvent {
    Dawn,
    Sunrise,
    Noon,
    Sunset,
    Dusk,
}

impl SunEvent {
    /// The key's word.
    pub fn name(self) -> &'static str {
        match self {
            Self::Dawn => "dawn",
            Self::Sunrise => "sunrise",
            Self::Noon => "noon",
            Self::Sunset => "sunset",
            Self::Dusk => "dusk",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        [Self::Dawn, Self::Sunrise, Self::Noon, Self::Sunset, Self::Dusk]
            .into_iter()
            .find(|e| e.name() == text)
    }
}

/// When an entry starts.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum When {
    /// Minutes after local midnight.
    Clock { minutes: i32 },
    /// A sun event moved by `offset` seconds.
    Sun { event: SunEvent, offset: f64 },
}

impl When {
    /// Swift's `"\(when)"`, the sort key that makes two readings of one object compare equal.
    fn sort_key(&self) -> String {
        match self {
            Self::Clock { minutes } => format!("clock(minutes: {minutes})"),
            Self::Sun { event, offset } => format!("sun({}, offset: {offset:?})", event.name()),
        }
    }
}

/// One entry: from `when`, show `value`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub when: When,
    pub value: String,
}

fn digits(text: &str) -> bool {
    text.chars().all(|c| c.is_ascii_digit())
}

/// Reads one key; nil for anything else.
pub fn when(text: &str) -> Option<When> {
    if let Some((hour, minute)) = text.split_once(':') {
        let (hours, minutes) = (hour.chars().count(), minute.chars().count());
        if !(1..=2).contains(&hours) || minutes != 2 || !digits(hour) || !digits(minute) {
            return None;
        }
        let (h, m): (i32, i32) = (hour.parse().ok()?, minute.parse().ok()?);
        return ((0..24).contains(&h) && (0..60).contains(&m))
            .then_some(When::Clock { minutes: h * 60 + m });
    }
    let sign = text.find(['+', '-']).unwrap_or(text.len());
    let event = SunEvent::parse(&text[..sign])?;
    if sign == text.len() {
        return Some(When::Sun { event, offset: 0.0 });
    }
    let mut amount = text[sign + 1..].to_string();
    let unit = amount.pop()?;
    if !(unit == 'm' || unit == 'h') || amount.is_empty() || !digits(&amount) {
        return None;
    }
    let count: u32 = amount.parse().ok()?;
    if count > if unit == 'm' { 1_440 } else { 24 } {
        return None;
    }
    let seconds = f64::from(count) * if unit == 'h' { 3_600.0 } else { 60.0 };
    Some(When::Sun {
        event,
        offset: if text.as_bytes()[sign] == b'-' { -seconds } else { seconds },
    })
}

/// Sorts entries as Swift's init does (by `"\(when)"`, then value).
pub fn sorted(mut entries: Vec<Entry>) -> Vec<Entry> {
    entries.sort_by(|a, b| (a.when.sort_key(), &a.value).cmp(&(b.when.sort_key(), &b.value)));
    entries
}

/// Reads a schedule object; nil when any key or value is bad (`is_value` checks a value).
pub fn parse(
    members: &BTreeMap<String, String>,
    is_value: impl Fn(&str) -> bool,
) -> Option<Vec<Entry>> {
    let mut entries = Vec::new();
    for (key, value) in members {
        let start = when(key)?;
        if !is_value(value) {
            return None;
        }
        entries.push(Entry { when: start, value: value.clone() });
    }
    Some(sorted(entries))
}

/// Whether an entry names a sun event (a location is needed).
pub fn uses_sun(entries: &[Entry]) -> bool {
    entries.iter().any(|e| matches!(e.when, When::Sun { .. }))
}

/// What a schedule shows at `t` and when that next changes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Resolved {
    pub value: Option<String>,
    pub next: Option<f64>,
}

/// The value shown at `t`, and the next instant it changes, from occurrences over a week around it.
pub fn resolve(entries: &[Entry], t: f64, location: Option<&Location>, zone: &Zone) -> Resolved {
    if entries.is_empty() {
        return Resolved { value: None, next: None };
    }
    let sun = uses_sun(entries);
    let mut times: Vec<(f64, &str)> = Vec::new();
    for day in -3..=3 {
        let start = zone.start_of_day_offset(t, day);
        let events = if sun { location.map(|l| sun_events(l, start, zone)) } else { None };
        for entry in entries {
            if let Some(time) = occurrence(&entry.when, start, events.as_ref(), zone) {
                times.push((time, &entry.value));
            }
        }
    }
    times.sort_by(|a, b| a.0.total_cmp(&b.0));
    let value = times.iter().rev().find(|x| x.0 <= t).map(|x| x.1.to_string());
    let next = times.iter().find(|x| x.0 > t).map(|x| x.0);
    Resolved { value, next }
}

/// One entry's instant on the day starting at `day_start`.
pub fn occurrence(
    when: &When,
    day_start: f64,
    sun: Option<&SunEvents>,
    zone: &Zone,
) -> Option<f64> {
    match *when {
        When::Clock { minutes } => Some(wall_time(minutes * 60, day_start, zone)),
        When::Sun { event, offset } => {
            let sun = sun?;
            let time = match event {
                SunEvent::Dawn => sun.dawn,
                SunEvent::Sunrise => sun.sunrise,
                SunEvent::Noon => Some(sun.noon),
                SunEvent::Sunset => sun.sunset,
                SunEvent::Dusk => sun.dusk,
            };
            time.map(|t| t + offset)
        }
    }
}

/// The instant the local wall clock reads `seconds` after midnight on the day starting at
/// `day_start`: the first reading when a fall-back repeats it, the transition when a gap skips it.
pub fn wall_time(seconds: i32, day_start: f64, zone: &Zone) -> f64 {
    zone.instant(zone.wall(day_start) + f64::from(seconds))
}
