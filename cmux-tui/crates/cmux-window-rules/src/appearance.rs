//! The appearance verbs' rules: `appearance.set|reset` at a level (which
//! level and property a run names, whether the property is set there, which
//! theme action a level's theme goes through), the focus ring style's edits,
//! and what the Base Keymap toast says.

use serde::{Deserialize, Serialize};

/// The levels a run may name (`app` and `rule` are cmux.json's, not a verb's).
const LEVELS: [&str; 4] = ["window", "workspace", "pane", "tab"];
/// The properties of `AppearanceProperty`.
const PROPERTIES: [&str; 7] =
    ["theme", "background", "tint", "opacity", "blur", "fontSize", "cursorStyle"];

/// The levels a person (or agent) may set `property` at (`AppearanceProperty.levels`).
pub fn property_levels(property: &str) -> &'static [&'static str] {
    match property {
        "theme" => &["app", "window", "workspace", "rule", "pane", "tab"],
        "background" => &["app", "window", "workspace", "rule", "pane"],
        "tint" => &["window", "workspace", "rule", "pane", "tab"],
        "opacity" => &["app", "window", "workspace", "pane"],
        "blur" => &["app", "window"],
        "fontSize" | "cursorStyle" => &["app", "workspace", "rule", "pane", "tab"],
        _ => &[],
    }
}

fn set_at(property: &str, level: &str) -> bool {
    property_levels(property).contains(&level)
}

/// What an `appearance.set|reset` run names.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppearanceAsk {
    /// The `scope` argument.
    pub scope: Option<String>,
    /// The `property` argument.
    pub property: Option<String>,
    /// `set`, else `reset`.
    pub set: bool,
}

/// Why an appearance verb did nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AppearanceRefusal {
    /// No scope or property it knows (and `set` needs a property).
    BadProperty,
    /// The property is not set at that level.
    NotAtLevel,
}

/// What an appearance verb does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "decision")]
pub enum Appearance {
    Apply {
        level: String,
        /// The theme goes through this action (its own saved rows), with the value as its `theme`.
        theme_action: Option<&'static str>,
        /// The properties the verb writes (set: the one named; reset: the named one, else every one
        /// set at the level), less a theme that goes through `theme_action`.
        properties: Vec<String>,
    },
    Refused {
        refusal: AppearanceRefusal,
    },
}

/// The theme action of a level: window, workspace and tab themes keep their own saved rows.
pub fn theme_action(level: &str, set: bool) -> Option<&'static str> {
    Some(match (level, set) {
        ("window", true) => "space.setTheme",
        ("window", false) => "space.clearTheme",
        ("workspace", true) => "workspace.setTheme",
        ("workspace", false) => "workspace.clearTheme",
        ("tab", true) => "terminal.setTheme",
        ("tab", false) => "terminal.clearTheme",
        _ => return None,
    })
}

fn refused(refusal: AppearanceRefusal) -> Appearance {
    Appearance::Refused { refusal }
}

/// `appearance.set` (a property at a level) or `appearance.reset` (one
/// property, else every one, at a level). The property's value check stays
/// with its owner.
pub fn appearance(ask: AppearanceAsk) -> Appearance {
    let Some(level) = ask.scope.filter(|scope| LEVELS.contains(&scope.as_str())) else {
        return refused(AppearanceRefusal::BadProperty);
    };
    let property = match ask.property {
        Some(property) if PROPERTIES.contains(&property.as_str()) => Some(property),
        Some(_) => return refused(AppearanceRefusal::BadProperty),
        None => None,
    };
    let theme_action = theme_action(&level, ask.set);
    if ask.set {
        let Some(property) = property else { return refused(AppearanceRefusal::BadProperty) };
        if !set_at(&property, &level) {
            return refused(AppearanceRefusal::NotAtLevel);
        }
        let forwarded = property == "theme" && theme_action.is_some();
        let properties = if forwarded { Vec::new() } else { vec![property] };
        return Appearance::Apply {
            level,
            theme_action: theme_action.filter(|_| forwarded),
            properties,
        };
    }
    let named: Vec<String> = match property {
        Some(property) => vec![property],
        None => PROPERTIES.iter().map(|&property| property.to_owned()).collect(),
    };
    let forwarded = theme_action.filter(|_| named.iter().any(|property| property == "theme"));
    // A reset skips a property not set at the level, as a set refuses it.
    let properties = named
        .into_iter()
        .filter(|property| property != "theme" || forwarded.is_none())
        .filter(|property| set_at(property, &level))
        .collect();
    Appearance::Apply { level, theme_action: forwarded, properties }
}

/// One cmux.json edit: the key path under the root and its value.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Edit {
    pub path: Vec<&'static str>,
    pub value: EditValue,
}

/// A value an edit writes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum EditValue {
    Text(String),
    Flag(bool),
}

/// Choosing a focus ring style also turns the ring on.
pub fn focus_ring_style(style: &str, was_enabled: bool) -> Vec<Edit> {
    let mut edits =
        vec![Edit { path: vec!["focusRing", "style"], value: EditValue::Text(style.to_owned()) }];
    if !was_enabled {
        edits.push(Edit { path: vec!["focusRing", "enabled"], value: EditValue::Flag(true) });
    }
    edits
}

/// A line of the Base Keymap toast.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum KeymapLine {
    /// "Base Keymap: <preset>".
    Title,
    NoChanges,
    /// iTerm2's Cmd-1…9 select tabs, workspaces move to Cmd-Opt-1…9.
    ITerm2Numbers,
}

/// The Base Keymap toast.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeymapToast {
    pub lines: Vec<KeymapLine>,
    /// It offers Undo (nothing to undo when nothing changed).
    pub undo: bool,
    pub seconds: u32,
}

/// What the toast after a Base Keymap switch says.
pub fn keymap_toast(preset: &str, changed: &[String]) -> KeymapToast {
    let mut lines = vec![KeymapLine::Title];
    if changed.is_empty() {
        lines.push(KeymapLine::NoChanges);
    }
    if preset == "iterm2" && changed.iter().any(|action| action == "selectSurfaceByNumber") {
        lines.push(KeymapLine::ITerm2Numbers);
    }
    KeymapToast {
        lines,
        undo: !changed.is_empty(),
        seconds: if changed.is_empty() { 6 } else { 10 },
    }
}

#[cfg(test)]
#[path = "appearance_tests.rs"]
mod tests;
