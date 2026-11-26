//! Where the sun is and when it rises (Swift `Sun.swift`): NOAA's solar position equations,
//! good to about a minute, which is all a wallpaper's moment needs.

use super::location::Location;
use super::zone::Zone;
use serde::{Deserialize, Serialize};

/// The sun's place in the sky, in degrees: altitude above the horizon, azimuth clockwise from north.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SunPosition {
    pub altitude: f64,
    pub azimuth: f64,
}

/// The altitude below which the sky counts as dark (civil twilight's end).
pub const DARK_ALTITUDE: f64 = -6.0;

impl SunPosition {
    /// The angle in degrees between two sun positions on the sky.
    pub fn angle(&self, other: &SunPosition) -> f64 {
        let (a1, a2) = (radians(self.altitude), radians(other.altitude));
        let delta = radians(self.azimuth - other.azimuth);
        let cosine = a1.sin() * a2.sin() + a1.cos() * a2.cos() * delta.cos();
        degrees(cosine.clamp(-1.0, 1.0).acos())
    }

    /// Whether the sun is at or below [`DARK_ALTITUDE`].
    pub fn is_dark(&self) -> bool {
        self.altitude <= DARK_ALTITUDE
    }
}

/// One local day's sun events (Unix seconds); an event the sun never reaches that day is `None`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SunEvents {
    pub dawn: Option<f64>,
    pub sunrise: Option<f64>,
    pub noon: f64,
    pub sunset: Option<f64>,
    pub dusk: Option<f64>,
}

fn radians(v: f64) -> f64 {
    v * std::f64::consts::PI / 180.0
}

fn degrees(v: f64) -> f64 {
    v * 180.0 / std::f64::consts::PI
}

/// The sun's position at `t` (Unix seconds) seen from `location`.
pub fn sun_position(location: &Location, t: f64) -> SunPosition {
    let solar = Solar::new(t);
    let minutes = (t % 86_400.0) / 60.0;
    let true_solar = (minutes + solar.equation_of_time + 4.0 * location.longitude) % 1_440.0;
    let mut hour_angle = true_solar / 4.0 - 180.0;
    if hour_angle < -180.0 {
        hour_angle += 360.0;
    }
    let lat = radians(location.latitude);
    let declination = solar.declination;
    let cos_zenith = (lat.sin() * declination.sin()
        + lat.cos() * declination.cos() * radians(hour_angle).cos())
    .clamp(-1.0, 1.0);
    let zenith = cos_zenith.acos();
    let denominator = lat.cos() * zenith.sin();
    let mut azimuth = 180.0;
    if denominator.abs() > 1e-9 {
        let cos_azimuth =
            ((lat.sin() * cos_zenith - declination.sin()) / denominator).clamp(-1.0, 1.0);
        let angle = degrees(cos_azimuth.acos());
        azimuth = if hour_angle > 0.0 { (angle + 180.0) % 360.0 } else { (540.0 - angle) % 360.0 };
    }
    SunPosition { altitude: 90.0 - degrees(zenith), azimuth }
}

/// The sun events of the local day holding `t` in `zone`.
pub fn sun_events(location: &Location, t: f64, zone: &Zone) -> SunEvents {
    let start = zone.start_of_day(t);
    let mut noon = solar_noon(location, start + 12.0 * 3_600.0);
    noon = solar_noon(location, noon);
    let event = |zenith: f64, rising: bool| -> Option<f64> {
        let mut guess = noon;
        for _ in 0..3 {
            let angle = Solar::new(guess).hour_angle(zenith, location.latitude)?;
            let offset = 4.0 * degrees(angle) * 60.0;
            let target = solar_noon(location, guess);
            guess = if rising { target - offset } else { target + offset };
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

/// Solar noon of the UTC day nearest `t`.
fn solar_noon(location: &Location, t: f64) -> f64 {
    let day = (t / 86_400.0).floor() * 86_400.0;
    let mut minutes = 720.0 - 4.0 * location.longitude - Solar::new(t).equation_of_time;
    let seconds = t - day;
    if minutes * 60.0 - seconds > 43_200.0 {
        minutes -= 1_440.0;
    } else if seconds - minutes * 60.0 > 43_200.0 {
        minutes += 1_440.0;
    }
    day + minutes * 60.0
}

struct Solar {
    declination: f64,
    equation_of_time: f64,
}

impl Solar {
    fn new(t: f64) -> Self {
        let century = (t / 86_400.0 + 2_440_587.5 - 2_451_545.0) / 36_525.0;
        let mean_longitude =
            radians((280.46646 + century * (36000.76983 + century * 0.0003032)) % 360.0);
        let anomaly = radians(357.52911 + century * (35999.05029 - 0.0001537 * century));
        let eccentricity = 0.016708634 - century * (0.000042037 + 0.0000001267 * century);
        let center = anomaly.sin() * (1.914602 - century * (0.004817 + 0.000014 * century))
            + (2.0 * anomaly).sin() * (0.019993 - 0.000101 * century)
            + (3.0 * anomaly).sin() * 0.000289;
        let omega = radians(125.04 - 1_934.136 * century);
        let apparent = mean_longitude + radians(center - 0.00569 - 0.00478 * omega.sin());
        let mean_obliquity = 23.0
            + (26.0
                + (21.448 - century * (46.815 + century * (0.00059 - century * 0.001813))) / 60.0)
                / 60.0;
        let obliquity = radians(mean_obliquity + 0.00256 * omega.cos());
        let declination = (obliquity.sin() * apparent.sin()).asin();
        let y = (obliquity / 2.0).tan().powi(2);
        let equation_of_time = 4.0
            * degrees(
                y * (2.0 * mean_longitude).sin() - 2.0 * eccentricity * anomaly.sin()
                    + 4.0 * eccentricity * y * anomaly.sin() * (2.0 * mean_longitude).cos()
                    - 0.5 * y * y * (4.0 * mean_longitude).sin()
                    - 1.25 * eccentricity * eccentricity * (2.0 * anomaly).sin(),
            );
        Self { declination, equation_of_time }
    }

    fn hour_angle(&self, zenith: f64, latitude: f64) -> Option<f64> {
        let lat = radians(latitude);
        let cosine = radians(zenith).cos() / (lat.cos() * self.declination.cos())
            - lat.tan() * self.declination.tan();
        (-1.0..=1.0).contains(&cosine).then(|| cosine.acos())
    }
}
