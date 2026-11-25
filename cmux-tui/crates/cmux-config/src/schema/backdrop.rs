//! The automatic background values (Swift `BackdropSelectionSetting+Switch`):
//! a fixed picture (`appearance.backgroundLight` / `appearance.backgroundDark`
//! and each schedule entry), the time-of-day schedule
//! (`appearance.backgroundSchedule`) and the sun location
//! (`appearance.backgroundLocation`), and what each mode last showed
//! (`appearance.backgroundMemory`), and the backgrounds shown before
//! (`appearance.backgroundRecents`, newest first).

use serde_json::Value;

use super::{DomainKind, Kind, Row, Schema, Validation};
use crate::text::trim_whitespaces;

/// The row whose choices are the fixed backgrounds (the bundled art and
/// `desktop`, Swift `BackdropSelectionSetting.catalogChoices`).
const PICTURE_ROW: &str = "appearance.backgroundLight";

/// The row whose choices are the background modes and the bundled art.
const SELECTION_ROW: &str = "appearance.background";

/// How many earlier backgrounds `appearance.backgroundRecents` keeps.
pub const RECENTS_CAP: usize = 8;

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

/// JSON Schema pattern of a live wallpaper (see [`is_live`]).
pub(crate) const LIVE_PATTERN: &str =
    "^live:([a-z][a-z0-9]*(-[a-z0-9]+)*/)?[a-z][a-z0-9]*(-[a-z0-9]+)*$";

/// A live wallpaper (plans/cmux-next/live-wallpapers.md): `live:<id>` for a
/// first-party one, `live:<extension>/<id>` for an extension's. Each part is a
/// cmux-wallpaper id: lowercase words joined by `-`, at most 48 bytes. An id
/// no wallpaper has falls back in the app like a missing picture.
pub(crate) fn is_live(text: &str) -> bool {
    let is_id = |s: &str| {
        s.len() <= 48
            && s.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
            && s.split('-').all(|part| {
                !part.is_empty()
                    && part.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
            })
    };
    let Some(rest) = text.strip_prefix("live:") else { return false };
    match rest.split_once('/') {
        Some((extension, id)) => is_id(extension) && is_id(id),
        None => is_id(rest),
    }
}

/// The living wallpapers, drawn live by a shader (Swift `BackdropShader`'s
/// raw values; `shader:` plus one is a background id). The test
/// `shader_names_match_swift` holds this list to the Swift enum, so a new
/// shader the app draws is one a theme file, a recipe or an agent may pick.
pub(crate) const SHADERS: [&str; 12] = [
    "currents", "ripples", "aurora", "field", "aero", "sakura", "sumi", "koi", "snowfall",
    "lanterns", "rain", "matrix",
];

/// The prefix of a living wallpaper's id (Swift `BackdropShader.idPrefix`).
pub(crate) const SHADER_PREFIX: &str = "shader:";

/// `shader:NAME` for a shader in [`SHADERS`].
pub(crate) fn is_shader(text: &str) -> bool {
    text.strip_prefix(SHADER_PREFIX).is_some_and(|name| SHADERS.contains(&name))
}

/// Every living wallpaper's id (`shader:aurora`, ...), in the Swift picker's order.
pub(crate) fn shader_ids() -> Vec<String> {
    SHADERS.iter().map(|name| format!("{SHADER_PREFIX}{name}")).collect()
}

/// Swift `BackdropSelectionSetting.picture`: `system:` or `file:` with an
/// absolute path, a canonical `youtube:` video (crate::youtube), a living
/// wallpaper (`shader:NAME`), or a listed fixed background.
pub fn is_picture(text: &str) -> bool {
    is_path_or_video(text) || picture_choices().iter().any(|choice| choice == text)
}

/// `system:` or `file:` with an absolute path, a canonical `youtube:` id or a
/// living wallpaper: the one-picture ids every background row takes beside
/// its listed choices (Swift `BackdropSelection(id:)`).
pub(crate) fn is_path_or_video(text: &str) -> bool {
    let path = ["system:", "file:"]
        .iter()
        .any(|prefix| text.strip_prefix(prefix).is_some_and(|path| path.starts_with('/')));
    path || crate::youtube::is_canonical_id(text) || is_shader(text)
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
pub fn is_schedule(value: &Value) -> bool {
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
pub fn is_location(text: &str) -> bool {
    let parts: Vec<&str> = text.split(',').map(trim_whitespaces).collect();
    let [latitude, longitude] = parts.as_slice() else {
        return false;
    };
    let number = |part: &str| part.parse::<f64>().ok().filter(|x| x.is_finite());
    number(latitude).is_some_and(|x| x.abs() <= 90.0)
        && number(longitude).is_some_and(|x| x.abs() <= 180.0)
}

/// Swift `BackdropSelectionSetting.acceptsMemory`: `appearance.backgroundMemory`,
/// what each background mode last showed. An object with at most `rotate`
/// (`daily` or a folder), `folder` (a folder) and `off` (`none` or a fixed
/// picture); any other member is refused.
pub fn is_memory(value: &Value) -> bool {
    value.as_object().is_some_and(|members| {
        members.iter().all(|(name, value)| {
            let Some(text) = value.as_str() else {
                return false;
            };
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

/// A value `appearance.background` takes: a listed choice (`none`,
/// `daily`, `appearance`, `schedule`, the bundled art, `desktop`), a
/// `system:` / `file:` picture, a `youtube:` video or a folder.
pub fn is_selection(text: &str) -> bool {
    is_path_or_video(text) || is_folder(text) || selection_choices().iter().any(|c| c == text)
}

/// The listed values of `appearance.background`: its modes and the bundled art.
pub(crate) fn selection_choices() -> Vec<String> {
    match Schema::embedded().row(SELECTION_ROW).map(|row| &row.kind) {
        Some(Kind::Choice(choices)) => choices.iter().map(|choice| choice.value.clone()).collect(),
        _ => Vec::new(),
    }
}

/// `appearance.backgroundRecents`: at most [`RECENTS_CAP`] distinct
/// background values ([`is_selection`]), newest first.
pub fn is_recents(value: &Value) -> bool {
    let Some(items) = value.as_array() else { return false };
    let mut seen = std::collections::HashSet::new();
    items.len() <= RECENTS_CAP
        && items
            .iter()
            .all(|item| item.as_str().is_some_and(|text| is_selection(text) && seen.insert(text)))
}

/// `recents` after `previous` stopped showing: `previous` first, any older
/// copy of it gone, at most [`RECENTS_CAP`] entries. A value that is not a
/// background, or an entry that is not one, is left out, so a list a person
/// broke by hand heals on the next change.
pub fn record_recent(recents: &[String], previous: &str) -> Vec<String> {
    let mut next = Vec::with_capacity(RECENTS_CAP);
    if is_selection(previous) {
        next.push(previous.to_string());
    }
    for item in recents {
        if next.len() == RECENTS_CAP {
            break;
        }
        if is_selection(item) && !next.contains(item) {
            next.push(item.clone());
        }
    }
    next
}

/// The background Switch to Previous Background shows instead of `current`:
/// the newest recent that is not `current`. Swapping writes `current` to the
/// front of the list, so a second swap comes back.
pub fn previous_background(current: &str, recents: &[String]) -> Option<String> {
    recents.iter().find(|item| item.as_str() != current && is_selection(item)).cloned()
}

/// The strings of an `appearance.backgroundRecents` value (anything else: none).
pub fn recents_of(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| item.to_string()).collect()
    }

    #[test]
    fn record_recent_puts_the_previous_first_once() {
        assert_eq!(record_recent(&[], "daily"), list(&["daily"]));
        let recents = list(&["folder:/Walls", "desktop", "daily"]);
        assert_eq!(record_recent(&recents, "daily"), list(&["daily", "folder:/Walls", "desktop"]));
        assert_eq!(
            record_recent(&recents, "file:/a.png"),
            list(&["file:/a.png", "folder:/Walls", "desktop", "daily"])
        );
    }

    #[test]
    fn record_recent_caps_and_refuses_junk() {
        let many: Vec<String> = (0..12).map(|n| format!("file:/p{n}.png")).collect();
        let next = record_recent(&many, "folder:/Walls");
        assert_eq!(next.len(), RECENTS_CAP);
        assert_eq!(next[0], "folder:/Walls");
        assert_eq!(next[1], "file:/p0.png");
        assert_eq!(record_recent(&list(&["daily"]), "not a background"), list(&["daily"]));
        assert_eq!(
            record_recent(&list(&["junk", "folder:/", "desktop"]), "none"),
            list(&["none", "desktop"])
        );
        assert!(is_recents(&Value::Array(next.iter().cloned().map(Value::String).collect())));
    }

    #[test]
    fn previous_background_swaps_back_and_forth() {
        // A rotating folder, then one picture: the swap goes to the folder, and back.
        let mut current = "file:/Users/me/harbor.png".to_string();
        let mut recents = list(&["folder:/Users/me/Walls"]);
        for expected in
            ["folder:/Users/me/Walls", "file:/Users/me/harbor.png", "folder:/Users/me/Walls"]
        {
            let previous = previous_background(&current, &recents).expect("a previous one");
            assert_eq!(previous, expected);
            recents = record_recent(&recents, &current);
            current = previous;
        }
        assert_eq!(previous_background("daily", &list(&["daily"])), None);
        assert_eq!(previous_background("daily", &[]), None);
        assert_eq!(
            previous_background("daily", &list(&["daily", "junk", "desktop"])),
            Some("desktop".into())
        );
    }

    #[test]
    fn recents_accepts_backgrounds_only() {
        use serde_json::json;
        assert!(is_recents(&json!([])));
        assert!(is_recents(&json!([
            "daily",
            "folder:/Walls",
            "desktop",
            "none",
            "file:/a.png",
            "schedule"
        ])));
        for bad in [
            json!("daily"),
            json!(["daily", "daily"]),
            json!(["folder:/"]),
            json!(["file:relative.png"]),
            json!([1]),
            json!(["__not_a_backdrop__"]),
            json!(["a", "b", "c", "d", "e", "f", "g", "h", "i"].map(|n| format!("file:/{n}.png"))),
        ] {
            assert!(!is_recents(&bad), "{bad}");
        }
    }

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
    fn live_wallpapers_are_live_ids() {
        let pattern = regex::Regex::new(LIVE_PATTERN).expect("pattern");
        for good in ["live:orbits", "live:grain-silk", "live:my-ext/neon-2"] {
            assert!(is_live(good), "{good}");
            assert!(pattern.is_match(good), "{good}");
        }
        for bad in [
            "live:",
            "live:Orbits",
            "live:-orbits",
            "live:grain--silk",
            "live:2d",
            "live:a/b/c",
            "live:/orbits",
            "orbits",
            "file:/live:orbits",
        ] {
            assert!(!is_live(bad), "{bad}");
            assert!(!pattern.is_match(bad), "{bad}");
        }
        assert!(!is_live(&format!("live:{}", "a".repeat(49))));
    }

    #[test]
    fn locations_are_lat_lon() {
        assert!(is_location("37.77,-122.42"));
        assert!(is_location("-33.87, 151.21"));
        for bad in ["", "37.77", "91,0", "0,181", "north,east", "1,2,3"] {
            assert!(!is_location(bad), "{bad}");
        }
    }

    /// The Swift enum's cases, read from its source: the app draws exactly
    /// the living wallpapers the schema lets a theme file or recipe pick.
    #[test]
    fn shader_names_match_swift() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropShader.swift"
        );
        let Ok(text) = std::fs::read_to_string(path) else {
            // A crate-only checkout has no Swift tree; the full repo always does.
            return;
        };
        let body = text.split("enum BackdropShader").nth(1).expect("the enum");
        let body = &body[..body.find("public static").expect("the enum's first member")];
        let swift: Vec<&str> = body
            .lines()
            .filter_map(|line| line.trim().strip_prefix("case "))
            .map(|name| name.split([' ', '=']).next().unwrap_or(name).trim())
            .collect();
        assert_eq!(swift, SHADERS, "SHADERS must list BackdropShader's cases, in order");
    }

    #[test]
    fn every_listed_shader_is_a_background_and_others_are_not() {
        for id in shader_ids() {
            assert!(is_picture(&id), "{id}");
            assert!(is_path_or_video(&id), "{id}");
        }
        for bad in ["shader:", "shader:nope", "shader:Aurora", "aurora", "shader:aurora "] {
            assert!(!is_shader(bad), "{bad}");
        }
    }
}
