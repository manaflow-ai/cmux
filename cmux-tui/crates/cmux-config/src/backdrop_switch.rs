//! The automatic backgrounds' decisions, with the time as an input: how often a
//! shuffle turns (`BackdropRotation`), which picture a Time of Day schedule
//! shows and when it next changes (`BackdropTimeOfDay`), and where the sun is
//! (`Sun.swift`). The app hands in the clock (epoch seconds) and its time zone;
//! nothing here reads either. Ported from the Swift in CmuxNextDesign so the two
//! agree to the second; the Swift tests are ported below.

use chrono::{Datelike, NaiveDate, Offset as _, TimeZone as _};

/// A time zone: an IANA name, or a fixed offset from UTC.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Zone {
    Named(chrono_tz::Tz),
    Fixed(i32),
}

impl Zone {
    /// UTC offset in seconds at `t` (epoch seconds).
    pub fn offset_at(self, t: f64) -> i32 {
        match self {
            Zone::Fixed(seconds) => seconds,
            Zone::Named(tz) => {
                let utc = chrono::DateTime::from_timestamp(t.floor() as i64, 0).unwrap_or_default();
                tz.offset_from_utc_datetime(&utc.naive_utc()).fix().local_minus_utc()
            }
        }
    }

    /// The local calendar date at `t`.
    pub fn date_at(self, t: f64) -> NaiveDate {
        let local = (t + f64::from(self.offset_at(t))).div_euclid(86_400.0) as i64;
        NaiveDate::from_num_days_from_ce_opt(local as i32 + 719_163).unwrap_or_default()
    }

    /// The first instant after `after` where the offset differs (Foundation's
    /// `nextDaylightSavingTimeTransition`), looked for within three days.
    fn next_transition(self, after: f64) -> Option<f64> {
        let base = self.offset_at(after);
        let mut low = after;
        let mut step = 0.0;
        while step < 3.0 * 86_400.0 {
            step += 900.0;
            let high = after + step;
            if self.offset_at(high) != base {
                let (mut lo, mut hi) = (low, high);
                while hi - lo > 1.0 {
                    let mid = ((lo + hi) / 2.0).floor();
                    if self.offset_at(mid) != base { hi = mid } else { lo = mid }
                }
                return Some(hi);
            }
            low = high;
        }
        None
    }

    /// The instant whose local wall clock reads `wall` seconds (as if UTC):
    /// the first of a repeated time, the transition for a skipped one.
    fn local_to_utc(self, wall: f64) -> f64 {
        let mut offsets = vec![
            self.offset_at(wall - 86_400.0),
            self.offset_at(wall),
            self.offset_at(wall + 86_400.0),
        ];
        offsets.sort_unstable();
        offsets.dedup();
        let candidates: Vec<f64> = offsets.iter().map(|o| wall - f64::from(*o)).collect();
        let valid = candidates
            .iter()
            .copied()
            .filter(|c| f64::from(self.offset_at(*c)) + c == wall)
            .fold(None, |best: Option<f64>, c| Some(best.map_or(c, |b| b.min(c))));
        if let Some(first) = valid {
            return first;
        }
        let earliest = candidates.iter().copied().fold(f64::INFINITY, f64::min);
        self.next_transition(earliest - 1.0).unwrap_or(earliest)
    }

    /// Local midnight of `date` (the first instant of that day).
    pub fn start_of_day(self, date: NaiveDate) -> f64 {
        let wall = f64::from(date.num_days_from_ce() - 719_163) * 86_400.0;
        self.local_to_utc(wall)
    }
}

/// How often a shuffle turns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rotation {
    QuarterHour,
    Hourly,
    Daily,
    Minutes(u32),
}

impl Rotation {
    pub const DEFAULT: Rotation = Rotation::Daily;

    /// `15m`, `hourly`, `daily`, or a whole number of minutes 1...1440.
    pub fn parse(text: &str) -> Option<Rotation> {
        match text {
            "15m" => Some(Rotation::QuarterHour),
            "hourly" => Some(Rotation::Hourly),
            "daily" => Some(Rotation::Daily),
            _ => {
                let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
                let ok = !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit());
                let count: i64 = if ok { text.parse().ok()? } else { return None };
                (1..=1_440).contains(&count).then_some(Rotation::Minutes(count as u32))
            }
        }
    }

    /// A number of minutes, rounded; only 1...1440.
    pub fn from_minutes(minutes: f64) -> Option<Rotation> {
        (minutes.is_finite() && (1.0..=1_440.0).contains(&minutes))
            .then(|| Rotation::Minutes(minutes.round() as u32))
    }

    /// The text a settings file holds.
    pub fn raw(self) -> String {
        match self {
            Rotation::QuarterHour => "15m".into(),
            Rotation::Hourly => "hourly".into(),
            Rotation::Daily => "daily".into(),
            Rotation::Minutes(count) => count.to_string(),
        }
    }

    fn seconds(self) -> f64 {
        match self {
            Rotation::Hourly => 3_600.0,
            Rotation::QuarterHour => 900.0,
            Rotation::Minutes(count) => f64::from(count.max(1)) * 60.0,
            Rotation::Daily => 86_400.0,
        }
    }

    /// The number of the period `t` is in (the day since the era's start for daily).
    pub fn period(self, t: f64, zone: Zone) -> i64 {
        match self {
            Rotation::Daily => i64::from(zone.date_at(t).num_days_from_ce()),
            _ => ((t + f64::from(zone.offset_at(t))) / self.seconds()).floor() as i64,
        }
    }

    /// When the next period starts.
    pub fn next_turn(self, t: f64, zone: Zone) -> f64 {
        match self {
            Rotation::Daily => zone.start_of_day(zone.date_at(t).succ_opt().unwrap_or_default()),
            _ => {
                let offset = f64::from(zone.offset_at(t));
                ((t + offset) / self.seconds()).floor() * self.seconds() + self.seconds() - offset
            }
        }
    }

    /// Which of `count` pictures shows at `t`; `None` for none.
    pub fn index(self, count: usize, t: f64, zone: Zone) -> Option<usize> {
        if count == 0 {
            return None;
        }
        let n = count as i64;
        let period = self.period(t, zone).rem_euclid(n);
        Some((period * daily_stride(count) as i64 % n) as usize)
    }
}

/// The step through a shuffle's pictures: the first of a fixed list coprime to `count`.
pub fn daily_stride(count: usize) -> usize {
    fn gcd(a: usize, b: usize) -> usize {
        if b == 0 { a } else { gcd(b, a % b) }
    }
    [97, 89, 83, 79, 73, 71, 67, 61, 59, 53].into_iter().find(|s| gcd(*s, count) == 1).unwrap_or(1)
}

/// A place on Earth, for the sun.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Location {
    pub latitude: f64,
    pub longitude: f64,
}

impl Location {
    /// `"LAT,LON"` (spaces around either allowed), within the globe.
    pub fn parse(text: &str) -> Option<Location> {
        let parts: Vec<&str> = text.split(',').map(crate::text::trim_whitespaces).collect();
        let [lat, lon] = parts[..] else { return None };
        let (latitude, longitude): (f64, f64) = (lat.parse().ok()?, lon.parse().ok()?);
        (latitude.is_finite()
            && longitude.is_finite()
            && latitude.abs() <= 90.0
            && longitude.abs() <= 180.0)
            .then_some(Location { latitude, longitude })
    }
}

/// The sun's place in the sky.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SunPosition {
    pub altitude: f64,
    pub azimuth: f64,
}

impl SunPosition {
    /// Below this altitude the sky is dark.
    pub const DARK_ALTITUDE: f64 = -6.0;

    pub fn is_dark(self) -> bool {
        self.altitude <= Self::DARK_ALTITUDE
    }
}

/// The sun's events of a day; `None` where the sun never crosses the line.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SunEvents {
    pub dawn: Option<f64>,
    pub sunrise: Option<f64>,
    pub noon: f64,
    pub sunset: Option<f64>,
    pub dusk: Option<f64>,
}

struct Solar {
    declination: f64,
    equation_of_time: f64,
}

impl Solar {
    fn at(t: f64) -> Solar {
        let century = (t / 86_400.0 + 2_440_587.5 - 2_451_545.0) / 36_525.0;
        let mean_longitude =
            ((280.46646 + century * (36_000.769_83 + century * 0.0003032)) % 360.0).to_radians();
        let anomaly = (357.52911 + century * (35_999.050_29 - 0.0001537 * century)).to_radians();
        let eccentricity = 0.016708634 - century * (0.000042037 + 0.0000001267 * century);
        let center = anomaly.sin() * (1.914602 - century * (0.004817 + 0.000014 * century))
            + (2.0 * anomaly).sin() * (0.019993 - 0.000101 * century)
            + (3.0 * anomaly).sin() * 0.000289;
        let omega = (125.04 - 1_934.136 * century).to_radians();
        let apparent = mean_longitude + (center - 0.00569 - 0.00478 * omega.sin()).to_radians();
        let mean_obliquity = 23.0
            + (26.0
                + (21.448 - century * (46.815 + century * (0.00059 - century * 0.001813))) / 60.0)
                / 60.0;
        let obliquity = (mean_obliquity + 0.00256 * omega.cos()).to_radians();
        let declination = (obliquity.sin() * apparent.sin()).asin();
        let y = (obliquity / 2.0).tan().powi(2);
        let equation_of_time = 4.0
            * (y * (2.0 * mean_longitude).sin() - 2.0 * eccentricity * anomaly.sin()
                + 4.0 * eccentricity * y * anomaly.sin() * (2.0 * mean_longitude).cos()
                - 0.5 * y * y * (4.0 * mean_longitude).sin()
                - 1.25 * eccentricity * eccentricity * (2.0 * anomaly).sin())
            .to_degrees();
        Solar { declination, equation_of_time }
    }

    fn hour_angle(&self, zenith: f64, latitude: f64) -> Option<f64> {
        let lat = latitude.to_radians();
        let cosine = zenith.to_radians().cos() / (lat.cos() * self.declination.cos())
            - lat.tan() * self.declination.tan();
        (-1.0..=1.0).contains(&cosine).then(|| cosine.acos())
    }
}

impl Location {
    /// Where the sun is at `t`.
    pub fn sun_position(self, t: f64) -> SunPosition {
        let solar = Solar::at(t);
        let minutes = (t % 86_400.0) / 60.0;
        let true_solar = (minutes + solar.equation_of_time + 4.0 * self.longitude) % 1_440.0;
        let mut hour_angle = true_solar / 4.0 - 180.0;
        if hour_angle < -180.0 {
            hour_angle += 360.0;
        }
        let lat = self.latitude.to_radians();
        let declination = solar.declination;
        let cos_zenith = (lat.sin() * declination.sin()
            + lat.cos() * declination.cos() * hour_angle.to_radians().cos())
        .clamp(-1.0, 1.0);
        let zenith = cos_zenith.acos();
        let denominator = lat.cos() * zenith.sin();
        let mut azimuth = 180.0;
        if denominator.abs() > 1e-9 {
            let cos_azimuth =
                ((lat.sin() * cos_zenith - declination.sin()) / denominator).clamp(-1.0, 1.0);
            let angle = cos_azimuth.acos().to_degrees();
            azimuth =
                if hour_angle > 0.0 { (angle + 180.0) % 360.0 } else { (540.0 - angle) % 360.0 };
        }
        SunPosition { altitude: 90.0 - zenith.to_degrees(), azimuth }
    }

    fn solar_noon(self, near: f64) -> f64 {
        let day = (near / 86_400.0).floor() * 86_400.0;
        let mut minutes = 720.0 - 4.0 * self.longitude - Solar::at(near).equation_of_time;
        let seconds = near - day;
        if minutes * 60.0 - seconds > 43_200.0 {
            minutes -= 1_440.0;
        } else if seconds - minutes * 60.0 > 43_200.0 {
            minutes += 1_440.0;
        }
        day + minutes * 60.0
    }

    /// The sun's events of the local day starting at `day_start`.
    pub fn sun_events(self, day_start: f64) -> SunEvents {
        let mut noon = self.solar_noon(day_start + 12.0 * 3_600.0);
        noon = self.solar_noon(noon);
        let event = |zenith: f64, rising: bool| -> Option<f64> {
            let mut guess = noon;
            for _ in 0..3 {
                let angle = Solar::at(guess).hour_angle(zenith, self.latitude)?;
                let offset = 4.0 * angle.to_degrees() * 60.0;
                let target = self.solar_noon(guess);
                guess = target + if rising { -offset } else { offset };
            }
            Some(guess)
        };
        SunEvents {
            dawn: event(96.0, true),
            sunrise: event(90.833, true),
            noon,
            sunset: event(90.833, false),
            dusk: event(96.0, false),
        }
    }
}

/// When a schedule entry fires.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum When {
    Clock { minutes: u32 },
    Sun { event: SunEvent, offset: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SunEvent {
    Dawn,
    Sunrise,
    Noon,
    Sunset,
    Dusk,
}

impl When {
    /// `H:MM`/`HH:MM`, or a sun event with an optional `+/-Nm` or `+/-Nh`.
    pub fn parse(text: &str) -> Option<When> {
        let digits = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit());
        if let Some((hour, minute)) = text.split_once(':') {
            let (hc, mc) = (hour.chars().count(), minute.chars().count());
            if !((1..=2).contains(&hc) && mc == 2 && digits(hour) && digits(minute)) {
                return None;
            }
            let (h, m): (u32, u32) = (hour.parse().ok()?, minute.parse().ok()?);
            return (h < 24 && m < 60).then_some(When::Clock { minutes: h * 60 + m });
        }
        let sign = text.find(['+', '-']).unwrap_or(text.len());
        let event = match &text[..sign] {
            "dawn" => SunEvent::Dawn,
            "sunrise" => SunEvent::Sunrise,
            "noon" => SunEvent::Noon,
            "sunset" => SunEvent::Sunset,
            "dusk" => SunEvent::Dusk,
            _ => return None,
        };
        if sign == text.len() {
            return Some(When::Sun { event, offset: 0.0 });
        }
        let rest = &text[sign + 1..];
        let unit = rest.chars().last()?;
        let amount = &rest[..rest.len() - unit.len_utf8()];
        if !(unit == 'm' || unit == 'h') || !digits(amount) {
            return None;
        }
        let count: u64 = amount.parse().ok()?;
        if count > if unit == 'm' { 1_440 } else { 24 } {
            return None;
        }
        let seconds = count as f64 * if unit == 'h' { 3_600.0 } else { 60.0 };
        Some(When::Sun {
            event,
            offset: if text.as_bytes()[sign] == b'-' { -seconds } else { seconds },
        })
    }
}

/// `appearance.backgroundSchedule`: when each picture shows.
#[derive(Debug, Clone, PartialEq)]
pub struct TimeOfDay {
    pub entries: Vec<(When, String)>,
}

impl TimeOfDay {
    /// Every key a time and every value accepted by `is_value`; otherwise `None`.
    pub fn parse<'a>(
        members: impl IntoIterator<Item = (&'a str, &'a str)>,
        is_value: impl Fn(&str) -> bool,
    ) -> Option<TimeOfDay> {
        let mut entries = Vec::new();
        for (key, value) in members {
            let when = When::parse(key)?;
            if !is_value(value) {
                return None;
            }
            entries.push((when, value.to_string()));
        }
        Some(TimeOfDay { entries })
    }

    fn uses_sun(&self) -> bool {
        self.entries.iter().any(|(when, _)| matches!(when, When::Sun { .. }))
    }

    /// The picture at `t` (the latest entry at or before it, across the week
    /// around it) and when it next changes. A sun entry needs `location`.
    pub fn resolve(
        &self,
        t: f64,
        location: Option<Location>,
        zone: Zone,
    ) -> (Option<String>, Option<f64>) {
        if self.entries.is_empty() {
            return (None, None);
        }
        let today = zone.date_at(t);
        let mut times: Vec<(f64, &str)> = Vec::new();
        for day in -3i64..=3 {
            let Some(other) = today.checked_add_signed(chrono::Duration::days(day)) else {
                continue;
            };
            let start = zone.start_of_day(other);
            let sun = if self.uses_sun() { location.map(|l| l.sun_events(start)) } else { None };
            for (when, value) in &self.entries {
                if let Some(time) = occurrence(*when, start, sun, zone) {
                    times.push((time, value));
                }
            }
        }
        times.sort_by(|a, b| a.0.total_cmp(&b.0));
        let shown = times.iter().rev().find(|(time, _)| *time <= t).map(|(_, v)| (*v).to_string());
        (shown, times.iter().find(|(time, _)| *time > t).map(|(time, _)| *time))
    }
}

fn occurrence(when: When, day_start: f64, sun: Option<SunEvents>, zone: Zone) -> Option<f64> {
    match when {
        When::Clock { minutes } => {
            let wall = day_start + f64::from(zone.offset_at(day_start)) + f64::from(minutes) * 60.0;
            Some(zone.local_to_utc(wall))
        }
        When::Sun { event, offset } => {
            let sun = sun?;
            let time = match event {
                SunEvent::Dawn => sun.dawn,
                SunEvent::Sunrise => sun.sunrise,
                SunEvent::Noon => Some(sun.noon),
                SunEvent::Sunset => sun.sunset,
                SunEvent::Dusk => sun.dusk,
            };
            time.map(|time| time + offset)
        }
    }
}

#[cfg(test)]
#[path = "backdrop_switch_tests.rs"]
mod tests;
