//! `keymap.*`: base keymap presets, the Ctrl-1...9 digit scheme, classic
//! cmux's recorded shortcuts, the keymap file's import edits and the
//! keyboard switches of cmux-next.json (Swift `ShortcutKeymapPreset`,
//! `ShortcutDigitScheme`, `ClassicShortcutImport`, `SettingsController+Keymap`,
//! `CommandDigitsSetting`, `SwapCmdTAndCmdNSetting`, `app.globalHotKey` and
//! `app.startAgentGlobalHotKey`). Bindings compare parsed ([`shortcut::parse`]),
//! so `opt+ctrl+1` equals `ctrl+opt+1`.
//!
//! `bindings` is cmux.json `shortcuts.bindings` merged over the legacy
//! `shortcuts.<id>` keys (`keymap.bindings`). A plan is
//! `{changes: [{action, write?}], kept: [id], edits: [{path, value?}]}`: a
//! change without `write` removes the override so the cmux default applies;
//! `edits` are the file edits that apply it (no `value` removes the path; a
//! removed override also goes from the legacy `shortcuts.<id>` form).
//!
//! Ops:
//! - `keymap.presets` `{}` answers `{presets: [name]}`.
//! - `keymap.plan` `{preset, bindings}` answers a plan; `keymap.active`
//!   `{bindings}` answers `{preset}` (null when the file mixes presets).
//! - `keymap.digit_plan` `{scheme, bindings}` answers a plan;
//!   `keymap.digit_active` `{bindings}` answers `{scheme}` (null when a digit
//!   binding was set by hand).
//! - `keymap.bindings` `{shortcuts}` answers `{bindings}`.
//! - `keymap.import_edits` `{value}` answers `{edits}` for a keymap file's
//!   JSON (fails when it is not an object).
//! - `keymap.classic_bindings` `{sources: [{prefsKey: text}]}` answers
//!   `{bindings: {classicID: value}}`: the shortcuts recorded in the first
//!   source that has any (`shortcut.<id>` keys, each a `StoredShortcut`'s
//!   JSON text). `keymap.classic_binding` `{text}` answers `{binding}` for one.
//! - `keymap.settings` `{root}` answers `{commandDigits, swapCmdTAndCmdN,
//!   globalHotKey, startAgentGlobalHotKey, diagnostics: [{kind, path, message}]}`.

use serde_json::{Map, Value, json};
use unicode_segmentation::UnicodeSegmentation;

use super::OpError;
use super::shortcut::{self, Binding};

/// A base keymap for people coming from another terminal: `shortcuts.bindings`
/// overrides, each different from the cmux default, so `cmux` has none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Preset {
    Cmux,
    ITerm2,
    Terminal,
    Tmux,
}

impl Preset {
    pub const ALL: [Preset; 4] = [Preset::Cmux, Preset::ITerm2, Preset::Terminal, Preset::Tmux];

    pub fn name(self) -> &'static str {
        match self {
            Preset::Cmux => "cmux",
            Preset::ITerm2 => "iterm2",
            Preset::Terminal => "terminal",
            Preset::Tmux => "tmux",
        }
    }

    pub fn named(name: &str) -> Option<Preset> {
        Self::ALL.into_iter().find(|preset| preset.name() == name)
    }

    /// The bindings this preset writes, in order, in the hand-editable
    /// cmux.json forms.
    pub fn overrides(self) -> Vec<(&'static str, Value)> {
        let tmux = |second: &str| json!(["ctrl+b", second]);
        match self {
            Preset::Cmux => vec![],
            Preset::ITerm2 => vec![
                ("selectSurfaceByNumber", json!("cmd+1")),
                ("selectWorkspaceByNumber", json!("cmd+opt+1")),
                ("toggleTerminalCopyMode", json!("cmd+shift+c")),
                ("resizePaneLeft", json!("cmd+ctrl+left")),
                ("resizePaneRight", json!("cmd+ctrl+right")),
                ("resizePaneUp", json!("cmd+ctrl+up")),
                ("resizePaneDown", json!("cmd+ctrl+down")),
            ],
            Preset::Terminal => vec![
                ("closeOtherTabsInPane", json!("cmd+opt+w")),
                ("renameTab", json!("cmd+shift+i")),
            ],
            Preset::Tmux => vec![
                ("newTab", tmux("c")),
                ("closeTab", tmux("x")),
                ("closeWorkspace", tmux("shift+7")),
                ("nextSidebarTab", tmux("n")),
                ("prevSidebarTab", tmux("p")),
                ("selectWorkspaceByNumber", tmux("1")),
                ("renameWorkspace", tmux(",")),
                ("goToWorkspace", tmux("w")),
                ("splitRight", tmux("shift+5")),
                ("splitDown", tmux("shift+'")),
                ("focusLeft", tmux("left")),
                ("focusRight", tmux("right")),
                ("focusUp", tmux("up")),
                ("focusDown", tmux("down")),
                ("focusNextPane", tmux("o")),
                ("toggleSplitZoom", tmux("z")),
                ("toggleTerminalCopyMode", tmux("[")),
            ],
        }
    }

    fn binding(self, action: &str) -> Option<Binding> {
        self.overrides()
            .into_iter()
            .find(|(id, _)| *id == action)
            .and_then(|(_, v)| shortcut::parse(&v))
    }

    /// This preset's actions in its order, then every other action some
    /// preset changes.
    fn action_ids(self) -> Vec<&'static str> {
        let mut ids: Vec<&'static str> = Vec::new();
        let all =
            self.overrides().into_iter().chain(Self::ALL.into_iter().flat_map(Preset::overrides));
        for (id, _) in all {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
        ids
    }

    /// The edits that switch `bindings` to this preset. A preset replaces only
    /// bindings that are absent or that some preset wrote (ownership inferred
    /// from values, as in the old app); one set by hand stays and is `kept`.
    pub fn plan(self, bindings: &Map<String, Value>) -> Plan {
        let overrides = self.overrides();
        let mut plan = Plan::default();
        for id in self.action_ids() {
            let current = bindings.get(id).and_then(shortcut::parse);
            let owned = current.as_ref().is_some_and(|value| {
                Self::ALL.iter().any(|p| p.binding(id).as_ref() == Some(value))
            });
            if let Some((_, target)) = overrides.iter().find(|(key, _)| *key == id) {
                if current == shortcut::parse(target) {
                    continue;
                }
                if bindings.contains_key(id) && !owned {
                    plan.kept.push(id.to_owned());
                    continue;
                }
                plan.changes.push((id.to_owned(), Some(target.clone())));
            } else if owned {
                plan.changes.push((id.to_owned(), None));
            }
        }
        plan
    }

    /// The preset `bindings` is on: switching to it changes nothing and at
    /// least one of its overrides is there (cmux when none is). `None` when
    /// the file mixes presets.
    pub fn active(bindings: &Map<String, Value>) -> Option<Preset> {
        for preset in Self::ALL.into_iter().filter(|p| *p != Preset::Cmux) {
            let applied = preset.overrides().iter().any(|(id, value)| {
                let current = bindings.get(*id).and_then(shortcut::parse);
                current.is_some() && current == shortcut::parse(value)
            });
            if applied && preset.plan(bindings).changes.is_empty() {
                return Some(preset);
            }
        }
        Preset::Cmux.plan(bindings).changes.is_empty().then_some(Preset::Cmux)
    }
}

/// What Ctrl-1...9 select: tabs (the default, Spaces on Ctrl-Opt-1...9) or
/// Spaces (tabs on Ctrl-Opt-1...9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DigitScheme {
    Tabs,
    Spaces,
}

impl DigitScheme {
    pub const ALL: [DigitScheme; 2] = [DigitScheme::Tabs, DigitScheme::Spaces];
    /// The action ids a scheme may write.
    pub const ACTION_IDS: [&'static str; 2] = ["space.selectByNumber", "selectSurfaceByNumber"];

    pub fn name(self) -> &'static str {
        match self {
            DigitScheme::Tabs => "tabs",
            DigitScheme::Spaces => "spaces",
        }
    }

    pub fn named(name: &str) -> Option<DigitScheme> {
        Self::ALL.into_iter().find(|scheme| scheme.name() == name)
    }

    /// The bindings this scheme writes; the default scheme writes none.
    pub fn overrides(self) -> Vec<(&'static str, Value)> {
        match self {
            DigitScheme::Tabs => vec![],
            DigitScheme::Spaces => vec![
                ("space.selectByNumber", json!("ctrl+1")),
                ("selectSurfaceByNumber", json!("ctrl+opt+1")),
            ],
        }
    }

    /// The catalog defaults of the digit actions (the tabs scheme).
    fn catalog_default(action: &str) -> Option<Value> {
        match action {
            "space.selectByNumber" => Some(json!("ctrl+opt+1")),
            "selectSurfaceByNumber" => Some(json!("ctrl+1")),
            _ => None,
        }
    }

    fn target(self, action: &str) -> Option<Value> {
        self.overrides().into_iter().find(|(id, _)| *id == action).map(|(_, v)| v)
    }

    /// The binding this scheme gives `action` (its override, else the default).
    fn binding(self, action: &str) -> Option<Binding> {
        self.target(action)
            .or_else(|| Self::catalog_default(action))
            .as_ref()
            .and_then(shortcut::parse)
    }

    fn owns(action: &str, current: Option<&Binding>) -> bool {
        current.is_some_and(|current| {
            Self::ALL.iter().any(|s| s.binding(action).as_ref() == Some(current))
        })
    }

    /// The edits that switch `bindings` to this scheme. A scheme owns a digit
    /// binding that is absent or equal to what some scheme gives it; any other
    /// value was set by hand, stays, and is `kept`.
    pub fn plan(self, bindings: &Map<String, Value>) -> Plan {
        let mut plan = Plan::default();
        for id in Self::ACTION_IDS {
            let current = bindings.get(id).and_then(shortcut::parse);
            let effective = current
                .clone()
                .or_else(|| Self::catalog_default(id).as_ref().and_then(shortcut::parse));
            if effective == self.binding(id) {
                continue;
            }
            if bindings.contains_key(id) && !Self::owns(id, current.as_ref()) {
                plan.kept.push(id.to_owned());
                continue;
            }
            plan.changes.push((id.to_owned(), self.target(id)));
        }
        plan
    }

    /// The scheme `bindings` is on: switching to it changes and keeps nothing.
    pub fn active(bindings: &Map<String, Value>) -> Option<DigitScheme> {
        Self::ALL.into_iter().find(|scheme| {
            let plan = scheme.plan(bindings);
            plan.changes.is_empty() && plan.kept.is_empty()
        })
    }
}

/// The `shortcuts.bindings` edits that switch cmux.json to a preset or scheme.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Plan {
    /// Each edit: the action and the value to write, or `None` to remove it.
    pub changes: Vec<(String, Option<Value>)>,
    /// Actions it would change but the user set by hand, left alone.
    pub kept: Vec<String>,
}

impl Plan {
    /// The file edits that apply the plan; a removed override also goes from
    /// the legacy `shortcuts.<id>` form.
    pub fn edits(&self) -> Vec<Value> {
        let mut edits = Vec::new();
        for (id, write) in &self.changes {
            edits.push(edit(&["shortcuts", "bindings", id], write.clone()));
            if write.is_none() {
                edits.push(edit(&["shortcuts", id], None));
            }
        }
        edits
    }

    fn json(&self) -> Value {
        let changes: Vec<Value> = self
            .changes
            .iter()
            .map(|(id, write)| match write {
                Some(value) => json!({ "action": id, "write": value }),
                None => json!({ "action": id }),
            })
            .collect();
        json!({ "changes": changes, "kept": self.kept, "edits": self.edits() })
    }
}

fn edit(path: &[&str], value: Option<Value>) -> Value {
    let mut out = Map::new();
    out.insert("path".to_owned(), json!(path));
    if let Some(value) = value {
        out.insert("value".to_owned(), value);
    }
    Value::Object(out)
}

/// The `shortcuts` keys that are not action ids.
pub const RESERVED_SHORTCUT_KEYS: [&str; 4] =
    ["bindings", "tiers", "when", "showModifierHoldHints"];

/// `shortcuts.bindings` merged over the legacy `shortcuts.<id>` keys, as the
/// snapshot reads them.
pub fn bindings(shortcuts: &Value) -> Map<String, Value> {
    let Some(section) = shortcuts.as_object() else { return Map::new() };
    let mut out: Map<String, Value> = section
        .iter()
        .filter(|(key, _)| !RESERVED_SHORTCUT_KEYS.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    if let Some(entries) = section.get("bindings").and_then(Value::as_object) {
        for (key, value) in entries {
            out.insert(key.clone(), value.clone());
        }
    }
    out
}

/// The `app` settings a keymap file carries besides `shortcuts`.
pub const KEYMAP_APP_KEYS: [&str; 2] = ["keyStyle", "shortcutLayout"];

/// The edits that import a keymap file: `app.keyStyle` and
/// `app.shortcutLayout` (no other `app` key), then each `shortcuts` member.
/// The file is `{"shortcuts": {...}}`, a bare `shortcuts` object (it has
/// `bindings`, `tiers` or `when`), or a bare bindings object.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub fn import_edits(value: &Value) -> Result<Vec<Value>, OpError> {
    let Some(root) = value.as_object() else {
        return Err(OpError::Invalid("keymap must be a JSON object".to_owned()));
    };
    let mut root = root.clone();
    let mut edits = Vec::new();
    if let Some(Value::Object(app)) = root.remove("app") {
        for key in KEYMAP_APP_KEYS {
            if let Some(value) = app.get(key) {
                edits.push(edit(&["app", key], Some(value.clone())));
            }
        }
    }
    let shortcuts = match root.get("shortcuts") {
        Some(Value::Object(nested)) => nested.clone(),
        _ if root.keys().any(|k| ["bindings", "tiers", "when"].contains(&k.as_str())) => root,
        _ if root.is_empty() => Map::new(),
        _ => Map::from_iter([("bindings".to_owned(), Value::Object(root))]),
    };
    // Swift walked a dictionary (no order); sorted keys keep the edit list stable.
    let mut keys: Vec<&String> = shortcuts.keys().collect();
    keys.sort();
    for key in keys {
        edits.push(edit(&["shortcuts", key], Some(shortcuts[key].clone())));
    }
    Ok(edits)
}

/// Classic's preference key prefix for a recorded shortcut.
pub const CLASSIC_PREFIX: &str = "shortcut.";

/// The shortcuts recorded in the first source that has any, by classic
/// action id, as next's binding object.
pub fn classic_bindings(sources: &[Value]) -> Map<String, Value> {
    for source in sources {
        let Some(entries) = source.as_object() else { continue };
        let mut found = Map::new();
        for (key, value) in entries {
            let Some(id) = key.strip_prefix(CLASSIC_PREFIX) else { continue };
            if let Some(binding) = value.as_str().and_then(classic_binding) {
                found.insert(id.to_owned(), binding);
            }
        }
        if !found.is_empty() {
            return found;
        }
    }
    Map::new()
}

/// Classic's `StoredShortcut` JSON as `{"first": {...}, "second": {...}}`,
/// or `None` for a key next can't bind (classic's media keys).
pub fn classic_binding(text: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(text).ok()?;
    let object = parsed.as_object()?;
    let mut members = Map::new();
    members.insert("first".to_owned(), classic_stroke(object, "key", None)?);
    if let Some(chord_key) = object.get("chordKey").and_then(Value::as_str)
        && !chord_key.is_empty()
    {
        members.insert("second".to_owned(), classic_stroke(object, "chordKey", Some("chord"))?);
    }
    let binding = Value::Object(members);
    shortcut::parse(&binding).map(|_| binding)
}

/// One stroke; `prefix` names the chord's modifier fields (`chordShift`).
fn classic_stroke(object: &Map<String, Value>, key: &str, prefix: Option<&str>) -> Option<Value> {
    let raw_key = object.get(key)?.as_str()?;
    if raw_key.graphemes(true).count() > 1 && shortcut::key_equivalent(raw_key).is_none() {
        return None;
    }
    let mut stroke = Map::new();
    stroke.insert("key".to_owned(), json!(raw_key));
    for modifier in ["command", "shift", "option", "control"] {
        let name = match prefix {
            Some(prefix) => {
                let mut chars = modifier.chars();
                let head = chars.next().map(|c| c.to_ascii_uppercase()).unwrap_or_default();
                format!("{prefix}{head}{}", chars.as_str())
            }
            None => modifier.to_owned(),
        };
        stroke.insert(
            modifier.to_owned(),
            json!(object.get(&name).and_then(ns_bool).unwrap_or(false)),
        );
    }
    Some(Value::Object(stroke))
}

/// Foundation's `as? Bool` on a JSONSerialization value: a JSON bool, or a
/// number that is exactly 0 or 1.
fn ns_bool(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(flag) => Some(*flag),
        Value::Number(number) => match number.as_f64() {
            Some(0.0) => Some(false),
            Some(1.0) => Some(true),
            _ => None,
        },
        _ => None,
    }
}

/// The keyboard switches of cmux-next.json. A missing key is the default with
/// no diagnostic; a bad value is the default plus a diagnostic.
pub fn settings(root: &Value) -> Value {
    let mut diagnostics = Vec::new();
    let at = |section: &str, key: &str| root.get(section).and_then(|s| s.get(key));
    let flag = |section: &str, key: &str, diagnostics: &mut Vec<Value>| match at(section, key) {
        None => false,
        Some(Value::Bool(on)) => *on,
        Some(_) => {
            diagnostics.push(invalid(&format!("{section}.{key}"), "expected true or false"));
            false
        }
    };
    let global = flag("app", "globalHotKey", &mut diagnostics);
    let start_agent = flag("app", "startAgentGlobalHotKey", &mut diagnostics);
    let swap = flag("tabs", "swapCmdTAndCmdN", &mut diagnostics);
    let digits = match at("tabs", "commandDigits") {
        None => "workspaces",
        Some(Value::String(text)) if text == "workspaces" || text == "tabs" => text.as_str(),
        Some(_) => {
            diagnostics
                .push(invalid("tabs.commandDigits", "expected one of \"workspaces\", \"tabs\""));
            "workspaces"
        }
    };
    json!({
        "commandDigits": digits,
        "swapCmdTAndCmdN": swap,
        "globalHotKey": global,
        "startAgentGlobalHotKey": start_agent,
        "diagnostics": diagnostics,
    })
}

fn invalid(path: &str, message: &str) -> Value {
    json!({ "kind": "invalidValue", "path": path, "message": message })
}

/// Runs a `keymap.*` op; `None` when `op` is not one.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "keymap.presets" => Ok(json!({ "presets": Preset::ALL.map(Preset::name) })),
        "keymap.plan" => plan_op(request, "preset", |name, bindings| {
            Preset::named(name).map(|preset| preset.plan(bindings))
        }),
        "keymap.active" => bindings_of(request)
            .map(|bindings| json!({ "preset": Preset::active(&bindings).map(Preset::name) })),
        "keymap.digit_plan" => plan_op(request, "scheme", |name, bindings| {
            DigitScheme::named(name).map(|scheme| scheme.plan(bindings))
        }),
        "keymap.digit_active" => bindings_of(request).map(
            |bindings| json!({ "scheme": DigitScheme::active(&bindings).map(DigitScheme::name) }),
        ),
        "keymap.bindings" => Ok(json!({
            "bindings": bindings(request.get("shortcuts").unwrap_or(&Value::Null)),
        })),
        "keymap.import_edits" => import_edits(request.get("value").unwrap_or(&Value::Null))
            .map(|edits| json!({ "edits": edits })),
        "keymap.classic_bindings" => match request.get("sources").and_then(Value::as_array) {
            Some(sources) => Ok(json!({ "bindings": classic_bindings(sources) })),
            None => Err(OpError::Invalid("expected an array `sources`".to_owned())),
        },
        "keymap.classic_binding" => {
            super::string(request, "text").map(|text| json!({ "binding": classic_binding(text) }))
        }
        "keymap.settings" => Ok(settings(request.get("root").unwrap_or(&Value::Null))),
        _ => return None,
    })
}

/// A plan op: the preset or scheme named by `key`, planned from `bindings`.
fn plan_op(
    request: &Value,
    key: &str,
    plan: impl Fn(&str, &Map<String, Value>) -> Option<Plan>,
) -> Result<Value, OpError> {
    let name = super::string(request, key)?;
    let bindings = bindings_of(request)?;
    plan(name, &bindings)
        .map(|plan| plan.json())
        .ok_or_else(|| OpError::Invalid(format!("unknown {key} `{name}`")))
}

/// The `bindings` object of a request (absent is empty).
fn bindings_of(request: &Value) -> Result<Map<String, Value>, OpError> {
    match request.get("bindings") {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::Object(bindings)) => Ok(bindings.clone()),
        Some(_) => Err(OpError::Invalid("expected an object `bindings`".to_owned())),
    }
}

#[cfg(test)]
#[path = "keymap_tests.rs"]
mod tests;
