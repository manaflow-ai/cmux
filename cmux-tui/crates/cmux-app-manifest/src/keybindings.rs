//! `contributes.keybindings`: shortcuts an app binds to its own catalog ops.
//! The daemon lists them with the app's commands (`apps-list` `commands[].keys`),
//! and the shell's app binding layer runs them through `app.command.run`, above
//! cmux's defaults and below the person's keybindings.json. The schema checks
//! the shape; here: one chord with a dispatcher modifier, no id or chord twice,
//! no chord the system owns, and every `onKeybinding:<id>` names a declared one.

use crate::issue::Issue;
use serde_json::Value;
use std::collections::HashSet;

/// Chords macOS or every app owns: an extension never binds them.
pub const RESERVED_KEYBINDINGS: &[&str] = &[
    "cmd+q",
    "cmd+h",
    "cmd+m",
    "cmd+tab",
    "cmd+space",
    "cmd+`",
    "cmd+alt+escape",
    "cmd+option+escape",
    "cmd+alt+h",
    "cmd+option+h",
];

/// The modifiers the shell's dispatcher matches; `shift` alone is not one.
const DISPATCH_MODIFIERS: &[&str] = &["cmd", "ctrl", "alt", "option", "opt"];

fn entries(m: &Value) -> impl Iterator<Item = (usize, &Value)> {
    m.pointer("/contributes/keybindings")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
}

/// The chord in one spelling (`option` and `opt` as `alt`, modifiers sorted),
/// so `shift+cmd+k` and `cmd+shift+k` are the same chord.
pub fn canonical_chord(key: &str) -> String {
    let mut parts: Vec<&str> = key.split('+').collect();
    let last = parts.pop().unwrap_or_default();
    let mut mods: Vec<&str> =
        parts.into_iter().map(|p| if p == "option" || p == "opt" { "alt" } else { p }).collect();
    mods.sort_unstable();
    mods.dedup();
    mods.push(last);
    mods.join("+")
}

/// Whether `key` holds a modifier the dispatcher runs (not only `shift`).
pub fn is_dispatch_chord(key: &str) -> bool {
    let mut parts = key.split('+');
    let last = parts.next_back().unwrap_or_default();
    !last.is_empty() && parts.any(|m| DISPATCH_MODIFIERS.contains(&m))
}

pub(crate) fn check(m: &Value, out: &mut Vec<Issue>) {
    let reserved: HashSet<String> =
        RESERVED_KEYBINDINGS.iter().map(|k| canonical_chord(k)).collect();
    let mut ids = HashSet::new();
    let mut chords = HashSet::new();
    if entries(m).next().is_some() && !m["catalog"].is_string() {
        out.push(Issue::error(
            "/contributes/keybindings",
            "keybindings.noCatalog",
            "a keybinding runs a catalog op: name the app's catalog.json in `catalog`",
        ));
    }
    for (i, entry) in entries(m) {
        let at = format!("/contributes/keybindings/{i}");
        let id = entry["id"].as_str().unwrap_or_default();
        if !ids.insert(id) {
            out.push(Issue::error(
                format!("{at}/id"),
                "keybindings.duplicate",
                format!("{id} is declared twice"),
            ));
        }
        let key = entry["key"].as_str().unwrap_or_default();
        if !is_dispatch_chord(key) {
            out.push(Issue::error(
                format!("{at}/key"),
                "keybindings.noModifier",
                format!(
                    "{key} needs cmd, ctrl or alt: a single key or shift+key would take typing"
                ),
            ));
            continue;
        }
        let chord = canonical_chord(key);
        if reserved.contains(&chord) {
            out.push(Issue::error(
                format!("{at}/key"),
                "keybindings.reserved",
                format!("{key} belongs to the system"),
            ));
        }
        let when = entry["when"].as_str().unwrap_or_default().to_string();
        if !chords.insert((chord, when)) {
            out.push(Issue::error(
                format!("{at}/key"),
                "keybindings.chordTwice",
                format!("{key} is bound twice with the same when"),
            ));
        }
    }
    for (i, trigger) in m["activation"].as_array().into_iter().flatten().enumerate() {
        let Some(id) = trigger.as_str().and_then(|t| t.strip_prefix("onKeybinding:")) else {
            continue;
        };
        if !ids.contains(id) {
            out.push(Issue::error(
                format!("/activation/{i}"),
                "keybindings.unknownActivation",
                format!("no contributes.keybindings entry has id {id}"),
            ));
        }
    }
}

/// A keybinding runs an op of the app's own catalog (`validate_package`).
pub(crate) fn check_ops(m: &Value, catalog: &Value, out: &mut Vec<Issue>) {
    let family = catalog["family"].as_str().unwrap_or_default();
    let names: HashSet<&str> = catalog["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| o["name"].as_str())
        .collect();
    for (i, entry) in entries(m) {
        let at = format!("/contributes/keybindings/{i}/op");
        let op = entry["op"].as_str().unwrap_or_default();
        if !op.starts_with(&format!("{family}.")) {
            out.push(Issue::error(
                at,
                "keybindings.foreignOp",
                format!("{op} is not an op of the app's own family {family}"),
            ));
        } else if !names.contains(op) {
            out.push(Issue::error(
                at,
                "keybindings.unknownOp",
                format!("{op} is not in the app's catalog"),
            ));
        }
    }
}
