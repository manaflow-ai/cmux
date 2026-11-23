//! The automatic background values (Swift `BackdropSelectionSetting+Switch`):
//! a fixed picture (`appearance.backgroundLight` / `appearance.backgroundDark`
//! and each schedule entry), the time-of-day schedule
//! (`appearance.backgroundSchedule`) and the sun location
//! (`appearance.backgroundLocation`), and what each mode last showed
//! (`appearance.backgroundMemory`).

use serde_json::Value;

use super::{DomainKind, Kind, Row, Schema, Validation};
use crate::text::trim_whitespaces;

/// The row whose choices are the fixed backgrounds (the bundled art and
/// `desktop`, Swift `BackdropSelectionSetting.catalogChoices`).
const PICTURE_ROW: &str = "appearance.backgroundLight";

/// The sun events a schedule key may name (Swift `BackdropTimeOfDay.SunEvent`).
const SUN_EVENTS: [&str; 5] = ["dawn", "sunrise", "noon", "sunset", "dusk"];

/// JSON Schema pattern of a schedule key (looser than [`is_when`] only in
/// the offset's size).
pub(crate) const WHEN_PATTERN: &str =
    "^(([01]?[0-9]|2[0-3]):[0-5][0-9]|(dawn|sunrise|noon|sunset|dusk)([+-][0-9]+[mh])?)$";

/// JSON Schema pattern of a `system:` or `file:` picture.
pub(crate) const PATH_PATTERN: &str = "^(system|file):/";

/// JSON Schema pattern of `LAT,LON`.
pub(crate) const LOCATION_PATTERN: &str =
    "^[ \\t]*[+-]?[0-9.]+([eE][+-]?[0-9]+)?[ \\t]*,[ \\t]*[+-]?[0-9.]+([eE][+-]?[0-9]+)?[ \\t]*$";

/// Swift `BackdropSelectionSetting.picture`: `system:` or `file:` with an
/// absolute path, a canonical `youtube:` video (crate::youtube), or a listed
/// fixed background.
pub(crate) fn is_picture(text: &str) -> bool {
    is_path_or_video(text) || picture_choices().iter().any(|choice| choice == text)
}

/// `system:` or `file:` with an absolute path, or a canonical `youtube:` id:
/// the one-picture ids every background row takes beside its listed choices.
pub(crate) fn is_path_or_video(text: &str) -> bool {
    let path = ["system:", "file:"]
        .iter()
        .any(|prefix| text.strip_prefix(prefix).is_some_and(|path| path.starts_with('/')));
    path || crate::youtube::is_canonical_id(text)
}

/// The fixed backgrounds the schema lists.
pub(crate) fn picture_choices() -> Vec<String> {
    match Schema::embedded().row(PICTURE_ROW).map(|row| &row.kind) {
        Some(Kind::Choice(choices)) => choices.iter().map(|choice| choice.value.clone()).collect(),
        _ => Vec::new(),
    }
}

/// `value` with each background id in it that claims YouTube (a pasted
/// address, a `youtube:` id in another order) as its canonical `youtube:` id,
/// for the rows that hold background ids: `appearance.background`, the light
/// and dark pictures and the schedule's pictures.
/// Every settings write runs it before validation (`settings.set`,
/// `settings.edit`, so the CLI, MCP and the app alike), so a pasted address
/// is stored as the id the app parses. A text that does not read as a
/// wallpaper is left as typed and the row's validation refuses it.
pub fn normalize_backdrop(row: &Row, value: Value) -> Value {
    let one = |value: Value| match value {
        Value::String(text) => Value::String(crate::youtube::normalize(&text).unwrap_or(text)),
        other => other,
    };
    let each = |value: Value| match value {
        Value::Object(members) => {
            Value::Object(members.into_iter().map(|(key, item)| (key, one(item))).collect())
        }
        other => other,
    };
    match row.validation {
        Validation::Domain(DomainKind::BackdropSelection | DomainKind::BackdropPicture) => {
            one(value)
        }
        Validation::Domain(DomainKind::BackdropSchedule) => each(value),
        _ => value,
    }
}

/// Swift `BackdropSelectionSetting.acceptsSchedule`: an object of valid
/// times to fixed pictures.
pub(crate) fn is_schedule(value: &Value) -> bool {
    value.as_object().is_some_and(|members| {
        members.iter().all(|(key, value)| is_when(key) && value.as_str().is_some_and(is_picture))
    })
}

/// Swift `BackdropTimeOfDay.when`: `H:MM` or `HH:MM` (24 h), or a sun event
/// with an optional `+N` / `-N` offset in `m` (at most 1440) or `h` (at most 24).
pub(crate) fn is_when(text: &str) -> bool {
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    if let Some((hour, minute)) = text.split_once(':') {
        return (1..=2).contains(&hour.len())
            && minute.len() == 2
            && digits(hour)
            && digits(minute)
            && hour.parse::<u32>().is_ok_and(|h| h < 24)
            && minute.parse::<u32>().is_ok_and(|m| m < 60);
    }
    let (event, amount) = match text.split_once(['+', '-']) {
        Some((event, amount)) => (event, Some(amount)),
        None => (text, None),
    };
    if !SUN_EVENTS.contains(&event) {
        return false;
    }
    let Some(amount) = amount else { return true };
    let (count, limit) = if let Some(count) = amount.strip_suffix('m') {
        (count, 1_440)
    } else if let Some(count) = amount.strip_suffix('h') {
        (count, 24)
    } else {
        return false;
    };
    digits(count) && count.parse::<u32>().is_ok_and(|n| n <= limit)
}

/// Swift `BackdropLocation(text:)`: `LAT,LON` with latitude in -90...90 and
/// longitude in -180...180, spaces around each allowed.
pub(crate) fn is_location(text: &str) -> bool {
    let parts: Vec<&str> = text.split(',').map(trim_whitespaces).collect();
    let [latitude, longitude] = parts.as_slice() else { return false };
    let number = |part: &str| part.parse::<f64>().ok().filter(|x| x.is_finite());
    number(latitude).is_some_and(|x| x.abs() <= 90.0)
        && number(longitude).is_some_and(|x| x.abs() <= 180.0)
}

/// Swift `BackdropSelectionSetting.acceptsMemory`: `appearance.backgroundMemory`,
/// what each background mode last showed. An object with at most `rotate`
/// (`daily` or a folder), `folder` (a folder) and `off` (`none` or a fixed
/// picture); any other member is refused.
pub(crate) fn is_memory(value: &Value) -> bool {
    value.as_object().is_some_and(|members| {
        members.iter().all(|(name, value)| {
            let Some(text) = value.as_str() else { return false };
            match name.as_str() {
                "rotate" => text == "daily" || is_folder(text),
                "folder" => is_folder(text),
                "off" => text == "none" || is_picture(text),
                _ => false,
            }
        })
    })
}

/// `folder:<absolute path>`, never `/` alone (Swift `BackdropSelectionSetting.folderPath`).
pub(crate) fn is_folder(text: &str) -> bool {
    text.strip_prefix("folder:").is_some_and(|path| path.starts_with('/') && path.len() > 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_keys_follow_swift() {
        for good in
            ["07:00", "9:30", "23:59", "sunset", "sunset-30m", "sunrise+1h", "dusk+90m", "noon"]
        {
            assert!(is_when(good), "{good}");
        }
        for bad in [
            "24:00",
            "07:60",
            "7",
            "sunset-",
            "sunset+30s",
            "midnight",
            "Sunset",
            "sunrise+25h",
            "07:0",
        ] {
            assert!(!is_when(bad), "{bad}");
        }
    }

    #[test]
    fn locations_are_lat_lon() {
        assert!(is_location("37.77,-122.42"));
        assert!(is_location("-33.87, 151.21"));
        for bad in ["", "37.77", "91,0", "0,181", "north,east", "1,2,3"] {
            assert!(!is_location(bad), "{bad}");
        }
    }
}
