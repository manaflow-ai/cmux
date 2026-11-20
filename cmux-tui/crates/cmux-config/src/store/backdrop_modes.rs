//! Switch Automatically never loses a mode's background (Leo, 2026-11-19: "switched around from the
//! rotating to day/night/whatever but it lost the folder or something idk i couldn't get back into
//! it?"). Off, Rotate and Sun keep their source in `appearance.background` itself (one picture, a
//! shuffle, a dynamic wallpaper), so any write that turns the background into another mode would
//! drop it. Every write and every hand edit that leaves one of the three records the source it
//! leaves in `appearance.backgroundModes`, whoever made it (Settings, the palette, `cmux settings`,
//! MCP, `cmux wallpaper` or an editor); the Settings page reads it back when the person switches
//! back. Light and Dark and Time of Day keep theirs in their own keys and need nothing here.

use serde_json::{Map, Value};

use crate::schema::backdrop::{is_dynamic_picture, is_picture, is_shuffle};
use crate::value::value_at;

/// `appearance.backgroundModes`.
pub(crate) const MODES_KEY: &str = "appearance.backgroundModes";
const MODES_PATH: [&str; 2] = ["appearance", "backgroundModes"];
const BACKGROUND_PATH: [&str; 2] = ["appearance", "background"];
const DYNAMIC_PATH: [&str; 2] = ["appearance", "backgroundDynamic"];

/// The modes of Settings' Switch Automatically (webviews `wallpaperSwitch.ts` `modeOf`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SwitchMode {
    Off,
    Appearance,
    Schedule,
    Sun,
    Rotate,
}

impl SwitchMode {
    /// Its member of `appearance.backgroundModes`; none for the modes with keys of their own.
    fn remembered(self) -> Option<&'static str> {
        match self {
            SwitchMode::Off => Some("off"),
            SwitchMode::Rotate => Some("rotate"),
            SwitchMode::Sun => Some("sun"),
            SwitchMode::Appearance | SwitchMode::Schedule => None,
        }
    }
}

/// The mode a file root's background is in, and the source it keeps in `appearance.background`.
pub(crate) fn switch_mode(root: &Value) -> (SwitchMode, Option<&str>) {
    let follows_time = value_at(root, &DYNAMIC_PATH).and_then(Value::as_str) == Some("time");
    match value_at(root, &BACKGROUND_PATH).and_then(Value::as_str) {
        None => (SwitchMode::Off, None),
        Some("appearance") => (SwitchMode::Appearance, None),
        Some("schedule") => (SwitchMode::Schedule, None),
        Some(raw) if is_shuffle(raw) => (SwitchMode::Rotate, Some(raw)),
        Some(raw) if follows_time && is_dynamic_picture(raw) => (SwitchMode::Sun, Some(raw)),
        Some(raw) => (SwitchMode::Off, Some(raw)),
    }
}

/// The `appearance.backgroundModes` value that keeps the source of the mode `before` leaves for
/// `after`; none when the mode stays, the mode has no source here, Off's is no picture (`none`
/// shows nothing to come back to) or the write set that member itself.
pub(crate) fn remembered_modes(before: &Value, after: &Value) -> Option<Value> {
    let (from, source) = switch_mode(before);
    let (to, _) = switch_mode(after);
    if from == to {
        return None;
    }
    let member = from.remembered()?;
    let source = source?;
    if from == SwitchMode::Off && !is_picture(source) {
        return None;
    }
    let kept =
        |root: &Value| value_at(root, &MODES_PATH).and_then(|modes| modes.get(member)).cloned();
    let now = kept(after);
    if now != kept(before) || now.as_ref().and_then(Value::as_str) == Some(source) {
        return None;
    }
    let mut members =
        value_at(after, &MODES_PATH).and_then(Value::as_object).cloned().unwrap_or_else(Map::new);
    members.insert(member.to_string(), Value::String(source.to_string()));
    Some(Value::Object(members))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const ART: &str = "file:/Users/me/Pictures/Harbor.png";
    const FOLDER: &str = "folder:/Users/me/Wallpapers";
    const SONOMA: &str = "system:/System/Library/Desktop Pictures/Sonoma.heic";

    /// The values each mode writes over `appearance.background` and `appearance.backgroundDynamic`.
    fn enter(mode: SwitchMode, root: &Value) -> Value {
        let mut next = root.clone();
        let appearance = next["appearance"].as_object_mut().unwrap();
        let (background, dynamic) = match mode {
            SwitchMode::Off => (ART, None),
            SwitchMode::Appearance => ("appearance", None),
            SwitchMode::Schedule => ("schedule", None),
            SwitchMode::Sun => (SONOMA, Some("time")),
            SwitchMode::Rotate => (FOLDER, None),
        };
        appearance.insert("background".into(), json!(background));
        match dynamic {
            Some(value) => appearance.insert("backgroundDynamic".into(), json!(value)),
            None => appearance.remove("backgroundDynamic"),
        };
        next
    }

    fn with_modes(mut root: Value, modes: Option<Value>) -> Value {
        if let Some(modes) = modes {
            root["appearance"]["backgroundModes"] = modes;
        }
        root
    }

    const ALL: [SwitchMode; 5] = [
        SwitchMode::Off,
        SwitchMode::Appearance,
        SwitchMode::Schedule,
        SwitchMode::Sun,
        SwitchMode::Rotate,
    ];

    #[test]
    fn every_mode_reads_back() {
        let base = json!({ "appearance": {} });
        for mode in ALL {
            assert_eq!(switch_mode(&enter(mode, &base)).0, mode, "{mode:?}");
        }
        assert_eq!(switch_mode(&json!({})), (SwitchMode::Off, None));
        assert_eq!(
            switch_mode(&json!({ "appearance": { "background": "daily" } })).0,
            SwitchMode::Rotate
        );
        // A dynamic picture on its light and dark frames is one picture: Off.
        assert_eq!(
            switch_mode(&json!({ "appearance": { "background": SONOMA } })).0,
            SwitchMode::Off
        );
    }

    /// Every ordered pair of modes: leaving Off, Rotate or Sun records its source, the others
    /// record nothing, and the source survives every later switch.
    #[test]
    fn every_switch_pair_keeps_the_mode_it_leaves() {
        let base = json!({ "appearance": {} });
        for from in ALL {
            for to in ALL {
                let before = enter(from, &base);
                let after = enter(to, &before);
                let modes = remembered_modes(&before, &after);
                let expected = match (from == to, from.remembered()) {
                    (true, _) | (_, None) => None,
                    (false, Some(member)) => {
                        Some(json!({ member: before["appearance"]["background"].clone() }))
                    }
                };
                assert_eq!(modes, expected, "{from:?} -> {to:?}");
            }
        }
    }

    /// The round trip through every mode and back: each remembered source is still there, and a
    /// member set before stays as the other members are added.
    #[test]
    fn a_round_trip_through_every_mode_keeps_every_source() {
        let mut root = json!({ "appearance": {} });
        let tour = [
            SwitchMode::Rotate,
            SwitchMode::Appearance,
            SwitchMode::Schedule,
            SwitchMode::Sun,
            SwitchMode::Off,
            SwitchMode::Rotate,
            SwitchMode::Sun,
            SwitchMode::Appearance,
            SwitchMode::Off,
        ];
        for mode in tour {
            let after = enter(mode, &root);
            let modes = remembered_modes(&root, &after);
            root = with_modes(after, modes);
        }
        assert_eq!(
            root["appearance"]["backgroundModes"],
            json!({ "rotate": FOLDER, "sun": SONOMA, "off": ART })
        );
    }

    #[test]
    fn nothing_to_keep() {
        // None shows nothing to come back to; an unset background has no source.
        let none = json!({ "appearance": { "background": "none" } });
        assert_eq!(remembered_modes(&none, &enter(SwitchMode::Rotate, &none)), None);
        let unset = json!({ "appearance": {} });
        assert_eq!(remembered_modes(&unset, &enter(SwitchMode::Rotate, &unset)), None);
        // Already kept: no write.
        let kept = with_modes(enter(SwitchMode::Rotate, &unset), Some(json!({ "rotate": FOLDER })));
        assert_eq!(remembered_modes(&kept, &enter(SwitchMode::Appearance, &kept)), None);
        // A writer that sets the member in the same write keeps its own value.
        let own =
            with_modes(enter(SwitchMode::Appearance, &kept), Some(json!({ "rotate": "daily" })));
        assert_eq!(remembered_modes(&kept, &own), None);
        // Another folder in Rotate replaces the kept one only when Rotate is left.
        let other = json!({ "appearance": { "background": "folder:/Other", "backgroundModes": { "rotate": FOLDER } } });
        assert_eq!(
            remembered_modes(&other, &enter(SwitchMode::Schedule, &other)),
            Some(json!({ "rotate": "folder:/Other" }))
        );
    }
}
