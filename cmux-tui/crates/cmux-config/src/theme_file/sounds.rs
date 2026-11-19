//! A theme file's sound pack (`"sounds"`): the sound each agent event plays
//! with this look. Not a setting: it never enters the overlay's values, and
//! the app plays it only while `notifications.sounds.lookPack` is on.
//!
//! ```jsonc
//! "sounds": { "finished": "Glass", "needsInput": "Ping", "ciGreen": "Hero" }
//! ```
//!
//! A value is a sound name (a macOS system or library sound: `Glass`),
//! `"none"` (silent for that event), `"file:NAME.ext"` (a sound file beside
//! the theme file) or a path at `~/`. A refused event or value is dropped with
//! a diagnostic; the rest of the pack and the file still apply.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::Reader;

/// The theme file key that holds the pack.
pub const KEY: &str = "sounds";
/// The events a pack sets: an agent's turn is done, an agent needs you, a
/// chat's PR checks went green.
pub const EVENTS: [&str; 3] = ["finished", "needsInput", "ciGreen"];
/// The value that silences an event.
pub const NONE: &str = "none";
/// The sound file types a `file:` or `~/` value may name.
pub const EXTENSIONS: [&str; 7] = ["aiff", "aif", "aifc", "caf", "wav", "mp3", "m4a"];
/// The longest value a pack takes.
const MAXIMUM_LENGTH: usize = 512;

const EXPECTED: &str = "expected a sound name (Glass), \"none\", \"file:NAME.ext\" beside the theme file or a path at ~/ (aiff, aif, aifc, caf, wav, mp3 or m4a)";

/// Whether `value` is a sound a pack may name.
pub fn is_valid_sound(value: &str) -> bool {
    if value.is_empty() || value.len() > MAXIMUM_LENGTH || value.chars().any(char::is_control) {
        return false;
    }
    if value == NONE {
        return true;
    }
    if let Some(name) = value.strip_prefix("file:") {
        return !name.contains('/') && !name.contains("..") && has_sound_extension(name);
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return !rest.split('/').any(|part| part.is_empty() || part == "." || part == "..")
            && has_sound_extension(rest);
    }
    // A system or library sound: a plain name, as Sound Settings lists it.
    value.len() <= 64
        && value == value.trim()
        && value.chars().all(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '_'))
}

/// `NAME.ext` with a non-empty NAME and a sound extension.
fn has_sound_extension(file: &str) -> bool {
    let file = file.rsplit('/').next().unwrap_or(file);
    file.rsplit_once('.').is_some_and(|(stem, ext)| {
        !stem.is_empty() && EXTENSIONS.iter().any(|known| known.eq_ignore_ascii_case(ext))
    })
}

/// The pack in `members`, each refused event or value reported on `reader`.
pub(super) fn read(
    reader: &mut Reader<'_>,
    members: &Map<String, Value>,
) -> BTreeMap<String, String> {
    let mut pack = BTreeMap::new();
    let Some(value) = members.get(KEY) else { return pack };
    let Value::Object(sounds) = value else {
        reader.refuse(
            KEY,
            Some(value),
            "expected an object of event sounds (finished, needsInput, ciGreen)",
        );
        return pack;
    };
    let mut events: Vec<&String> = sounds.keys().collect();
    events.sort();
    for event in events {
        let value = &sounds[event];
        let path = format!("{KEY}.{event}");
        if !EVENTS.contains(&event.as_str()) {
            reader.refuse(&path, Some(value), "expected an event: finished, needsInput, ciGreen");
            continue;
        }
        match value.as_str() {
            Some(sound) if is_valid_sound(sound) => {
                pack.insert(event.clone(), sound.to_string());
            }
            _ => reader.refuse(&path, Some(value), EXPECTED),
        }
    }
    pack
}

/// The JSON Schema of the `"sounds"` block, for the theme file schema.
pub fn json_schema() -> Value {
    // Lowercase only here, an editor's hint; the reader takes any case.
    let extensions = EXTENSIONS.join("|");
    let sound = json!({
        "type": "string",
        "anyOf": [
            { "const": NONE },
            { "pattern": format!("^file:(?!.*\\.\\.)[^/]+\\.({extensions})$") },
            { "pattern": format!("^~/(?!.*\\.\\.).+\\.({extensions})$") },
            { "pattern": "^[A-Za-z0-9_-][A-Za-z0-9 _-]{0,63}$" },
        ],
    });
    let descriptions = [
        ("finished", "An agent's turn is done."),
        ("needsInput", "An agent needs you."),
        ("ciGreen", "A chat's pull request checks went green."),
    ];
    let mut properties = Map::new();
    for (event, description) in descriptions {
        let mut schema = sound.clone();
        if let Some(members) = schema.as_object_mut() {
            members.insert("description".into(), json!(description));
        }
        properties.insert(event.into(), schema);
    }
    json!({
        "type": "object",
        "description": "The look's sound pack, played while notifications.sounds.lookPack is on: a sound name (Glass, Ping, Hero), \"none\", \"file:NAME.ext\" beside this file or a path at ~/.",
        "properties": Value::Object(properties),
        "additionalProperties": false,
    })
}
