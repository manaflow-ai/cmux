//! Dynamic macOS desktop pictures (Swift `LiveWallpaperDynamic` and the store-choice reader):
//! which frame of a HEIC shows at an instant, when that next changes, the frame tables read from
//! its `solar`, `h24` and `apr` metadata, and the desktop store's choice for a display.

use super::location::Location;
use super::sun::SunPosition;
use super::sun::sun_position;
use super::zone::Zone;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A solar frame: shown when the sun is nearest `position`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SolarFrame {
    pub position: SunPosition,
    pub index: usize,
}

/// A clock frame: shown from `time` (a fraction of the local day) on.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClockFrame {
    pub time: f64,
    pub index: usize,
}

/// A dynamic picture's frame tables.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frames {
    #[serde(default)]
    pub solar: Vec<SolarFrame>,
    #[serde(default)]
    pub clock: Vec<ClockFrame>,
    pub light: usize,
    pub dark: usize,
}

impl Frames {
    /// The frame shown at `t`: the solar frame nearest the sun (the first on a tie), else the
    /// clock frame in force (the last of the day before the first), else dark or light by the sun.
    pub fn frame(&self, t: f64, location: &Location, zone: &Zone) -> usize {
        if !self.solar.is_empty() {
            let sun = sun_position(location, t);
            let mut best = self.solar[0];
            let mut best_angle = sun.angle(&best.position);
            for frame in &self.solar[1..] {
                let angle = sun.angle(&frame.position);
                if angle < best_angle {
                    best = *frame;
                    best_angle = angle;
                }
            }
            return best.index;
        }
        if !self.clock.is_empty() {
            let fraction = zone.seconds_into_day(t) as f64 / 86_400.0;
            let mut clock = self.clock.clone();
            clock.sort_by(|a, b| a.time.total_cmp(&b.time));
            return clock
                .iter()
                .rev()
                .find(|f| f.time <= fraction)
                .or(clock.last())
                .map_or(self.light, |f| f.index);
        }
        if sun_position(location, t).is_dark() { self.dark } else { self.light }
    }

    /// The first instant after `t` the frame changes, within two days, to the second.
    pub fn next_change(&self, t: f64, location: &Location, zone: &Zone) -> Option<f64> {
        let current = self.frame(t, location, zone);
        let mut low = t;
        for step in 1..=576 {
            let high = t + f64::from(step) * 300.0;
            if self.frame(high, location, zone) != current {
                let mut high = high;
                while high - low > 1.0 {
                    let mid = (low + high) / 2.0;
                    if self.frame(mid, location, zone) == current {
                        low = mid;
                    } else {
                        high = mid;
                    }
                }
                return Some(high);
            }
            low = high;
        }
        None
    }
}

fn valid(value: Option<&Value>, count: usize) -> Option<usize> {
    let number = value?.as_f64()?;
    (number.fract() == 0.0 && number >= 0.0 && number < count as f64).then_some(number as usize)
}

/// Reads the frame tables from a picture's `apple_desktop` metadata plists (as JSON) for a
/// picture of `count` frames: the first of `solar`, `h24`, `apr` present supplies them all; nil
/// for a still picture or one with none.
pub fn read(
    solar: Option<&Value>,
    h24: Option<&Value>,
    apr: Option<&Value>,
    count: usize,
) -> Option<Frames> {
    if count <= 1 {
        return None;
    }
    let plist = solar.or(h24).or(apr)?;
    let pair = plist.get("ap").filter(|p| p.is_object()).unwrap_or(plist);
    let mut frames = Frames::default();
    for entry in plist.get("si").and_then(Value::as_array).into_iter().flatten() {
        let altitude = entry.get("a").and_then(Value::as_f64);
        let azimuth = entry.get("z").and_then(Value::as_f64);
        if let (Some(altitude), Some(azimuth), Some(index)) =
            (altitude, azimuth, valid(entry.get("i"), count))
        {
            frames.solar.push(SolarFrame { position: SunPosition { altitude, azimuth }, index });
        }
    }
    for entry in plist.get("ti").and_then(Value::as_array).into_iter().flatten() {
        if let (Some(time), Some(index)) =
            (entry.get("t").and_then(Value::as_f64), valid(entry.get("i"), count))
        {
            frames.clock.push(ClockFrame { time, index });
        }
    }
    let highest = first_by(&frames.solar, |a, b| a > b);
    let lowest = first_by(&frames.solar, |a, b| a < b);
    frames.light = valid(pair.get("l"), count).or(highest).unwrap_or(0);
    frames.dark = valid(pair.get("d"), count).or(lowest).unwrap_or(frames.light);
    Some(frames)
}

/// The index of the first solar frame whose altitude beats every other by `better`.
fn first_by(frames: &[SolarFrame], better: impl Fn(f64, f64) -> bool) -> Option<usize> {
    let mut best: Option<SolarFrame> = None;
    for frame in frames {
        if best.is_none_or(|b| better(frame.position.altitude, b.position.altitude)) {
            best = Some(*frame);
        }
    }
    best.map(|f| f.index)
}

/// Swift `BackdropAppearance.frame(in:)`: a dynamic picture's frame for the light or dark
/// appearance, looking in `apr`, then `solar`, then `h24`; 0 when none names one.
pub fn appearance_frame(
    apr: Option<&Value>,
    solar: Option<&Value>,
    h24: Option<&Value>,
    dark: bool,
    count: usize,
) -> usize {
    if count <= 1 {
        return 0;
    }
    for plist in [apr, solar, h24].into_iter().flatten() {
        let pair = plist.get("ap").filter(|p| p.is_object()).unwrap_or(plist);
        if let Some(index) = valid(pair.get(if dark { "d" } else { "l" }), count) {
            return index;
        }
        let mut positions = Vec::new();
        for entry in plist.get("si").and_then(Value::as_array).into_iter().flatten() {
            if let (Some(altitude), Some(index)) =
                (entry.get("a").and_then(Value::as_f64), valid(entry.get("i"), count))
            {
                positions
                    .push(SolarFrame { position: SunPosition { altitude, azimuth: 0.0 }, index });
            }
        }
        let pick = if dark {
            first_by(&positions, |a, b| a < b)
        } else {
            first_by(&positions, |a, b| a > b)
        };
        if let Some(index) = pick {
            return index;
        }
    }
    0
}

/// How the desktop store says a dynamic picture moves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Motion {
    /// With the time of day (the solar or clock tables).
    Time,
    /// With the system appearance (the light and dark frames).
    Appearance,
    Light,
    Dark,
}

/// One display's desktop choice as the store keeps it.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreChoice {
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub strings: Vec<String>,
}

impl StoreChoice {
    /// Whether the choice is an aerial (a video the app can't draw).
    pub fn is_aerial(&self) -> bool {
        self.provider.as_ref().is_some_and(|p| p.to_lowercase().contains("aerial"))
    }

    /// The aerial asset ids among the strings (none unless the choice is an aerial).
    pub fn aerial_ids(&self) -> Vec<String> {
        if !self.is_aerial() {
            return Vec::new();
        }
        self.strings
            .iter()
            .filter(|s| {
                (1..=64).contains(&s.len())
                    && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
                    && s.contains('-')
            })
            .cloned()
            .collect()
    }

    /// The file URLs and paths among the strings.
    pub fn files(&self) -> Vec<String> {
        self.strings
            .iter()
            .filter(|s| s.starts_with("file://") || s.starts_with('/'))
            .cloned()
            .collect()
    }

    /// The motion the strings name, the first that names one.
    pub fn motion(&self) -> Option<Motion> {
        self.strings.iter().find_map(|s| match s.to_lowercase().as_str() {
            "dynamic" | "timeofday" | "time-of-day" | "solar" => Some(Motion::Time),
            "automatic" | "auto" | "appearance" => Some(Motion::Appearance),
            "light" => Some(Motion::Light),
            "dark" => Some(Motion::Dark),
            _ => None,
        })
    }
}

fn collect_strings(value: &Value, depth: usize, out: &mut Vec<String>) {
    if depth >= 8 {
        return;
    }
    match value {
        Value::String(s) => out.push(s.clone()),
        Value::Array(items) => items.iter().for_each(|v| collect_strings(v, depth + 1, out)),
        Value::Object(members) => {
            if members.len() == 1
                && let Some(data) = members.get("$data")
            {
                collect_strings(data, depth + 1, out);
                return;
            }
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort();
            for key in keys {
                collect_strings(&members[key], depth + 1, out);
            }
        }
        _ => {}
    }
}

fn scope_choice(scope: &Value) -> Option<StoreChoice> {
    let desktop = scope.get("Desktop").filter(|d| d.is_object())?;
    let content = desktop.get("Content").filter(|c| c.is_object()).unwrap_or(desktop);
    let choice = content
        .get("Choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .filter(|c| c.is_object());
    let mut strings = Vec::new();
    collect_strings(choice.unwrap_or(content), 0, &mut strings);
    if choice.is_none() && strings.is_empty() {
        return None;
    }
    let provider =
        choice.and_then(|c| c.get("Provider")).and_then(Value::as_str).map(str::to_string);
    Some(StoreChoice { provider, strings })
}

/// Reads the desktop store (its plist as JSON; plist data as `{"$data": decoded}`) for a display
/// id: the display's own scope (key matched without case), then all spaces and displays.
pub fn read_store(root: &Value, display: Option<&str>) -> Option<StoreChoice> {
    let own = display.and_then(|display| {
        let displays = root.get("Displays")?.as_object()?;
        displays.iter().find(|(k, _)| k.to_lowercase() == display.to_lowercase()).map(|(_, v)| v)
    });
    [own, root.get("AllSpacesAndDisplays")]
        .into_iter()
        .flatten()
        .filter(|scope| scope.is_object())
        .find_map(scope_choice)
}

/// A store choice's moment: the frame index (none for appearance) and when it next changes.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Moment {
    pub index: Option<usize>,
    pub next: Option<f64>,
}

/// The frame a store choice shows at `t`: `motion` defaults to appearance for a picture with no
/// time tables, else time; appearance leaves the frame to the window's appearance (none).
pub fn frame_of(
    frames: Option<&Frames>,
    motion: Option<Motion>,
    t: f64,
    location: &Location,
    zone: &Zone,
) -> Moment {
    let Some(frames) = frames else { return Moment::default() };
    let motion = motion.unwrap_or(if frames.solar.is_empty() && frames.clock.is_empty() {
        Motion::Appearance
    } else {
        Motion::Time
    });
    match motion {
        Motion::Appearance => Moment::default(),
        Motion::Light => Moment { index: Some(frames.light), next: None },
        Motion::Dark => Moment { index: Some(frames.dark), next: None },
        Motion::Time => Moment {
            index: Some(frames.frame(t, location, zone)),
            next: frames.next_change(t, location, zone),
        },
    }
}

/// How long a cached moment holds: until its next change, else a minute.
pub fn moment_until(next: Option<f64>, t: f64) -> f64 {
    next.unwrap_or(t + 60.0)
}
