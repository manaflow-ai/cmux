//! Reading a cmux.json section into typed fields, with the app's diagnostics: Swift
//! `ConfigFieldReader`, `ColorTransitionSetting.parse`, `ComputerUseSettings`,
//! `BrowserHibernationSetting`, `ThemeEditsSetting`, `AgentPaneComposerSetting`,
//! `AgentPaneDictationShortcut`. The Swift side builds its structs from these answers.
//!
//! - `settings.reader_section` `{root, prefix, skip?}` reads the toggle, choice, number and
//!   text rows directly under the dotted `prefix` as `ConfigFieldReader` does: `{values,
//!   diagnostics}`; a bad value is its default plus a diagnostic, a number out of its range is
//!   clamped plus a diagnostic. `skip` lists keys the caller reads itself.
//! - `settings.rows_parse` `{root, keys}` reads whole keys by the row's `accepts` (what
//!   `descriptor.accepts` does): `{values, diagnostics}` with `expected ...` messages; a bad
//!   key keeps no value (the caller keeps its default).
//! - `computer_use.parse` `{root}` answers `{values, diagnostics}`;
//!   `computer_use.migrated_denied_apps` `{list}` answers `{list}` or `{}`;
//!   `computer_use.person_only` `{path}` answers `{person_only}`.
//! - `browser.hibernation` `{root}` answers the setting and `{diagnostics}`;
//!   `browser.hibernation_excludes` `{exclusions, host}` answers `{excluded}`;
//!   `browser.hibernation_add_exclusion` `{exclusions, host}` answers `{exclusions}`.
//! - `theme_edits.parse` `{root}` answers `{colors, diagnostics}`.
//! - `agent_pane.dictation_shortcut` `{text}` answers `{valid, modifiers?, key?}`.

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::domains::Domains;
use crate::schema::{self, Kind, NumberRange, Row, Schema};
use crate::text::{ThemeSpec, trim_whitespaces};

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "settings.reader_section" => reader_section(request),
        "settings.rows_parse" => rows_parse(request),
        "computer_use.parse" => computer_use(request),
        "computer_use.migrated_denied_apps" => migrated_denied_apps(request),
        "computer_use.person_only" => person_only(request),
        "browser.hibernation" => hibernation(request),
        "browser.hibernation_excludes" => hibernation_excludes(request),
        "browser.hibernation_add_exclusion" => hibernation_add_exclusion(request),
        "theme_edits.parse" => theme_edits(request),
        "agent_pane.dictation_shortcut" => dictation_shortcut(request),
        _ => return None,
    })
}

fn invalid(what: &str) -> OpError {
    OpError::Invalid(format!("expected {what}"))
}

fn root_of(request: &Value) -> Result<&Value, OpError> {
    request.get("root").ok_or_else(|| invalid("a `root`"))
}

fn path_of(prefix: &str) -> Vec<String> {
    prefix.split('.').map(str::to_owned).collect()
}

fn diagnostic(path: &str, message: impl Into<String>) -> Value {
    json!({"path": path, "message": message.into()})
}

/// A Swift `Double` in a message: `0.0`, `1000.0`, `0.42`.
fn swift_double(x: f64) -> String {
    if x.fract() == 0.0 && x.abs() < 1e15 { format!("{x:.1}") } else { format!("{x}") }
}

fn choices_text(choices: &[schema::Choice]) -> String {
    choices.iter().map(|c| format!("\"{}\"", c.value)).collect::<Vec<_>>().join(", ")
}

/// Swift `ConfigFieldReader`: one object of cmux.json read field by field.
struct Reader<'a> {
    members: &'a Map<String, Value>,
    path: String,
    diagnostics: Vec<Value>,
}

impl<'a> Reader<'a> {
    /// The object at `path`; `Err` with the diagnostics when it is not an object;
    /// `Ok(None)` when absent.
    fn new(root: &'a Value, path: &[String]) -> Result<Option<Self>, Vec<Value>> {
        let Some(value) = crate::value::value_at(root, path) else { return Ok(None) };
        let joined = path.join(".");
        match value.as_object() {
            Some(members) => Ok(Some(Reader { members, path: joined, diagnostics: Vec::new() })),
            None => Err(vec![diagnostic(&joined, "expected an object")]),
        }
    }

    fn fail(&mut self, key: &str, message: impl Into<String>) {
        self.diagnostics.push(diagnostic(&format!("{}.{key}", self.path), message));
    }

    fn bool(&mut self, key: &str) -> Option<bool> {
        let value = self.members.get(key)?;
        match value.as_bool() {
            Some(flag) => Some(flag),
            None => {
                self.fail(key, "expected true or false");
                None
            }
        }
    }

    fn number(&mut self, key: &str, range: &NumberRange) -> Option<f64> {
        let value = self.members.get(key)?;
        let Some(number) = value.as_f64().filter(|n| n.is_finite()) else {
            self.fail(key, "expected a number");
            return None;
        };
        if !(range.min..=range.max).contains(&number) {
            self.fail(
                key,
                format!("clamped to {}...{}", swift_double(range.min), swift_double(range.max)),
            );
        }
        Some(number.clamp(range.min, range.max))
    }

    fn choice(&mut self, key: &str, choices: &[schema::Choice]) -> Option<String> {
        let value = self.members.get(key)?;
        match value.as_str().filter(|text| choices.iter().any(|c| c.value == *text)) {
            Some(text) => Some(text.to_owned()),
            None => {
                self.fail(key, format!("expected one of {}", choices_text(choices)));
                None
            }
        }
    }

    fn string(&mut self, key: &str) -> Option<String> {
        let value = self.members.get(key)?;
        match value.as_str() {
            Some(text) => Some(text.to_owned()),
            None => {
                self.fail(key, "expected a string");
                None
            }
        }
    }

    /// A row's field by its kind; `None` for a kind this reader does not take.
    fn read(&mut self, row: &Row, key: &str) -> Option<Option<Value>> {
        Some(match &row.kind {
            Kind::Toggle => self.bool(key).map(Value::Bool),
            Kind::Choice(choices) => self.choice(key, choices).map(Value::String),
            Kind::Number(range) => self.number(key, range).map(|n| json!(n)),
            Kind::Text => self.string(key).map(Value::String),
            _ => return None,
        })
    }
}

fn direct_rows<'a>(
    schema: &'a Schema,
    prefix: &[String],
) -> impl Iterator<Item = (&'a Row, String)> + 'a {
    let prefix = prefix.to_vec();
    schema
        .rows
        .iter()
        .filter(move |row| {
            row.path.len() == prefix.len() + 1 && row.path[..prefix.len()] == prefix[..]
        })
        .map(move |row| (row, row.path[row.path.len() - 1].clone()))
}

fn read_rows(
    root: &Value,
    prefix: &[String],
    skip: &[String],
) -> Result<(Map<String, Value>, Vec<Value>), OpError> {
    let schema = Schema::embedded();
    let mut values = Map::new();
    let mut reader = match Reader::new(root, prefix) {
        Ok(reader) => reader,
        Err(diagnostics) => {
            for (row, key) in direct_rows(schema, prefix) {
                if let Some(default) = &row.default {
                    values.insert(key, default.clone());
                }
            }
            return Ok((values, diagnostics));
        }
    };
    for (row, key) in direct_rows(schema, prefix) {
        if skip.contains(&key) {
            continue;
        }
        let read = match reader.as_mut() {
            Some(reader) => reader.read(row, &key),
            None => Some(None),
        };
        let Some(read) = read else { continue };
        if let Some(value) = read.or_else(|| row.default.clone()) {
            values.insert(key, value);
        }
    }
    Ok((values, reader.map(|r| r.diagnostics).unwrap_or_default()))
}

fn reader_section(request: &Value) -> Result<Value, OpError> {
    let root = root_of(request)?;
    let prefix = path_of(string(request, "prefix")?);
    let skip: Vec<String> = request
        .get("skip")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
        .unwrap_or_default();
    let (values, diagnostics) = read_rows(root, &prefix, &skip)?;
    Ok(json!({"values": values, "diagnostics": diagnostics}))
}

/// Swift `OmnibarSettingsSchema.expectation`.
fn expectation(row: &Row) -> String {
    let whole = |range: &NumberRange| format!("from {} to {}", range.min as i64, range.max as i64);
    match &row.kind {
        Kind::Toggle => "expected true or false".to_owned(),
        Kind::Choice(choices) => format!("expected one of {}", choices_text(choices)),
        Kind::Number(range) => format!("expected a number {}", whole(range)),
        Kind::Url => "expected a web address or \"\"".to_owned(),
        Kind::ChoiceOrNumber(choices, range) => {
            format!("expected one of {} or a number {}", choices_text(choices), whole(range))
        }
        Kind::ChoiceOrUrl(choices, key) => format!(
            "expected one of {} or {{\"{key}\": \"http(s)://host[:port]\"}}",
            choices_text(choices)
        ),
        _ => "invalid value".to_owned(),
    }
}

fn rows_parse(request: &Value) -> Result<Value, OpError> {
    let root = root_of(request)?;
    let keys =
        request.get("keys").and_then(Value::as_array).ok_or_else(|| invalid("an array `keys`"))?;
    let schema = Schema::embedded();
    let domains = Domains::default();
    let (mut values, mut diagnostics) = (Map::new(), Vec::new());
    for key in keys.iter().filter_map(Value::as_str) {
        let Some(row) = schema.row(key) else { continue };
        let Some(value) = crate::value::value_at(root, &row.path) else { continue };
        if schema::accepts(row, value, &domains).is_ok() {
            values.insert(key.to_owned(), value.clone());
        } else {
            diagnostics.push(diagnostic(key, expectation(row)));
        }
    }
    Ok(json!({"values": values, "diagnostics": diagnostics}))
}

const EARLIER_MODES: [(&str, &str); 4] = [
    ("standard", "fullAccess"),
    ("unrestricted", "fullAccess"),
    ("bounded", "approvedApps"),
    ("ask", "askEveryTime"),
];

fn computer_use(request: &Value) -> Result<Value, OpError> {
    let root = root_of(request)?;
    let prefix = path_of("computerUse");
    let schema = Schema::embedded();
    let (mut values, mut diagnostics) = read_rows(root, &prefix, &["mode".to_owned()])?;
    let mode_row = schema.row("computerUse.mode");
    let default_mode = mode_row.and_then(|row| row.default.clone()).unwrap_or(json!("fullAccess"));
    values.insert("mode".to_owned(), default_mode);
    let object = crate::value::value_at(root, &prefix).and_then(Value::as_object);
    if let (Some(members), Some(row)) = (object, mode_row) {
        let raw = members.get("mode");
        let earlier = raw
            .and_then(Value::as_str)
            .and_then(|text| EARLIER_MODES.iter().find(|(old, _)| *old == text));
        if let Some((_, mode)) = earlier {
            values.insert("mode".to_owned(), json!(mode));
        } else if let (Some(raw), Kind::Choice(choices)) = (raw, &row.kind) {
            match raw.as_str().filter(|text| choices.iter().any(|c| c.value == *text)) {
                Some(text) => {
                    values.insert("mode".to_owned(), json!(text));
                }
                None => diagnostics.push(diagnostic(
                    "computerUse.mode",
                    format!("expected one of {}", choices_text(choices)),
                )),
            }
        } else if raw.is_none() && members.get("enabled").and_then(Value::as_bool) == Some(false) {
            // The retired switch: an old file's "enabled": false keeps Computer Use off.
            values.insert("mode".to_owned(), json!("off"));
        }
    }
    if let Some(value) = crate::value::value_at(root, &path_of("computerUse.deniedApps")) {
        let items = value
            .as_array()
            .filter(|items| items.iter().all(|v| v.as_str().is_some_and(|s| !s.is_empty())));
        match items {
            Some(items) => {
                let mut seen = std::collections::BTreeSet::new();
                let apps: Vec<&str> =
                    items.iter().filter_map(Value::as_str).filter(|s| seen.insert(*s)).collect();
                values.insert("deniedApps".to_owned(), json!(apps));
            }
            None => {
                diagnostics
                    .push(diagnostic("computerUse.deniedApps", "expected a list of app ids"));
            }
        }
    }
    Ok(json!({"values": values, "diagnostics": diagnostics}))
}

/// The entries earlier default deny lists held that today's does not.
const RETIRED_DENIED_APPS: [&str; 16] = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "org.alacritty",
    "dev.warp.*",
    "windowsterminal.exe",
    "cmd.exe",
    "powershell.exe",
    "pwsh.exe",
    "org.gnome.Terminal",
    "org.gnome.Ptyxis",
    "org.kde.konsole",
    "com.cmuxterm.app",
    "com.cmuxterm.app.*",
];

fn migrated_denied_apps(request: &Value) -> Result<Value, OpError> {
    let list: Vec<&str> = request
        .get("list")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("an array `list`"))?
        .iter()
        .filter_map(Value::as_str)
        .collect();
    let trimmed: std::collections::BTreeSet<&str> =
        list.iter().map(|s| trim_whitespaces(s)).collect();
    if !RETIRED_DENIED_APPS.iter().all(|entry| trimmed.contains(entry)) {
        return Ok(json!({}));
    }
    let kept: Vec<&str> =
        list.into_iter().filter(|s| !RETIRED_DENIED_APPS.contains(&trim_whitespaces(s))).collect();
    Ok(json!({"list": kept}))
}

fn person_only(request: &Value) -> Result<Value, OpError> {
    let first = request
        .get("path")
        .and_then(Value::as_array)
        .and_then(|p| p.first())
        .and_then(Value::as_str);
    Ok(json!({"person_only": first == Some("computerUse")}))
}

fn hibernation_row(key: &str) -> Option<&'static Row> {
    Schema::embedded().row(key)
}

fn hibernation(request: &Value) -> Result<Value, OpError> {
    let root = root_of(request)?;
    let default_of = |key: &str| hibernation_row(key).and_then(|row| row.default.clone());
    let mut mode = json!("moderate");
    let mut minutes = json!(30.0);
    let mut discards = false;
    let mut exclusions = default_of("browser.hibernationExclusions").unwrap_or(json!([]));
    let mut pinned =
        default_of("browser.hibernatePinnedTabs").and_then(|v| v.as_bool()).unwrap_or(false);
    let mut freeze = default_of("browser.freezeHiddenTabs").unwrap_or(json!(30));
    let mut radius = default_of("browser.keepNeighborTabsAwake").unwrap_or(json!(1));
    let mut hover =
        default_of("browser.wakeTabsOnHover").and_then(|v| v.as_bool()).unwrap_or(false);
    let mut diagnostics = Vec::new();
    if let Some(browser) = root.get("browser").and_then(Value::as_object) {
        let mut bad = |key: &str, message: &str| {
            diagnostics.push(diagnostic(&format!("browser.{key}"), message));
        };
        if let Some(value) = browser.get("hibernation") {
            let named = value.as_str().filter(|t| ["off", "moderate", "aggressive"].contains(t));
            if let Some(number) = value.as_f64().filter(|n| *n > 0.0) {
                (mode, minutes, discards) = (json!("minutes"), json!(number), true);
            } else if let Some(text) = named {
                minutes = match text {
                    "off" => Value::Null,
                    "aggressive" => json!(10.0),
                    _ => json!(30.0),
                };
                (mode, discards) = (json!(text), true);
            } else {
                bad(
                    "hibernation",
                    "expected \"off\", \"moderate\", \"aggressive\" or a number of minutes > 0",
                );
            }
        }
        if let Some(value) = browser.get("hibernationExclusions") {
            match value.as_array().filter(|items| items.iter().all(Value::is_string)) {
                Some(items) => {
                    let hosts: Vec<&str> =
                        items.iter().filter_map(Value::as_str).filter(|s| !s.is_empty()).collect();
                    exclusions = json!(hosts);
                }
                None => bad("hibernationExclusions", "expected an array of host names"),
            }
        }
        if let Some(value) = browser.get("hibernatePinnedTabs") {
            match value.as_bool() {
                Some(flag) => pinned = flag,
                None => bad("hibernatePinnedTabs", "expected true or false"),
            }
        }
        if let Some(value) = browser.get("freezeHiddenTabs") {
            if let Some(number) = value.as_f64().filter(|n| *n > 0.0) {
                freeze = json!(number);
            } else if value.as_str() == Some("off") {
                freeze = Value::Null;
            } else {
                bad("freezeHiddenTabs", "expected \"off\" or a number of seconds > 0");
            }
        }
        if let Some(value) = browser.get("keepNeighborTabsAwake") {
            let range =
                hibernation_row("browser.keepNeighborTabsAwake").and_then(|row| match &row.kind {
                    Kind::Number(range) => Some((range.min, range.max)),
                    _ => None,
                });
            let (lo, hi) = range.unwrap_or((0.0, 3.0));
            match value.as_f64().filter(|n| n.fract() == 0.0 && (lo..=hi).contains(n)) {
                Some(number) => radius = json!(number as i64),
                None => bad("keepNeighborTabsAwake", "expected a whole number from 0 to 3"),
            }
        }
        if let Some(value) = browser.get("wakeTabsOnHover") {
            match value.as_bool() {
                Some(flag) => hover = flag,
                None => bad("wakeTabsOnHover", "expected true or false"),
            }
        }
    }
    Ok(json!({
        "mode": mode, "hidden_minutes": minutes, "enabled": mode != json!("off"),
        "exclusions": exclusions, "includes_pinned_tabs": pinned, "freeze_seconds": freeze,
        "neighbor_radius": radius, "discards_automatically": discards, "wakes_on_hover": hover,
        "diagnostics": diagnostics,
    }))
}

fn exclusion_list(request: &Value) -> Result<Vec<String>, OpError> {
    Ok(request
        .get("exclusions")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid("an array `exclusions`"))?
        .iter()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect())
}

fn host_of(request: &Value) -> Option<String> {
    request.get("host").and_then(Value::as_str).map(str::to_lowercase).filter(|h| !h.is_empty())
}

fn excludes(exclusions: &[String], host: &str) -> bool {
    exclusions.iter().any(|pattern| {
        let pattern = pattern.to_lowercase();
        match pattern.strip_prefix('*') {
            Some(suffix) if suffix.starts_with('.') => host.ends_with(suffix),
            _ => host == pattern || host.ends_with(&format!(".{pattern}")),
        }
    })
}

fn hibernation_excludes(request: &Value) -> Result<Value, OpError> {
    let list = exclusion_list(request)?;
    Ok(json!({"excluded": host_of(request).is_some_and(|host| excludes(&list, &host))}))
}

fn hibernation_add_exclusion(request: &Value) -> Result<Value, OpError> {
    let mut list = exclusion_list(request)?;
    if let Some(host) = host_of(request).filter(|host| !excludes(&list, host)) {
        list.push(host);
    }
    Ok(json!({"exclusions": list}))
}

const THEME_EDIT_TOKENS: [&str; 21] = [
    "background",
    "foreground",
    "cursor",
    "selection",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "10",
    "11",
    "12",
    "13",
    "14",
    "15",
    "accent",
];

fn is_edit_color(text: &str) -> bool {
    text.len() == 7 && text.starts_with('#') && text[1..].bytes().all(|b| b.is_ascii_hexdigit())
}

fn theme_edits(request: &Value) -> Result<Value, OpError> {
    const PATH: &str = "appearance.themeEdits";
    let root = root_of(request)?;
    let none = json!({"colors": {}, "diagnostics": []});
    let Some(value) = crate::value::value_at(root, &path_of(PATH)) else { return Ok(none) };
    let Some(entries) = value.as_object() else {
        return Ok(json!({"colors": {}, "diagnostics": [diagnostic(PATH, "expected an object")]}));
    };
    let mut colors: std::collections::BTreeMap<String, Map<String, Value>> = Default::default();
    let mut diagnostics = Vec::new();
    for (key, entry) in entries {
        let at = format!("{PATH}.{key}");
        let name_token = key.rfind('/').map(|slash| (&key[..slash], &key[slash + 1..]));
        let Some((name, token)) = name_token.filter(|(name, _)| {
            ThemeSpec::parse(name).is_some_and(|theme| theme.light == *name && theme.dark == *name)
        }) else {
            diagnostics.push(diagnostic(
                &at,
                "expected \"<theme>/<token>\", such as \"Rose Pine/background\"",
            ));
            continue;
        };
        if !THEME_EDIT_TOKENS.contains(&token) {
            diagnostics.push(diagnostic(
                &at,
                "unknown token; expected background, foreground, cursor, selection, 0 to 15 or accent",
            ));
            continue;
        }
        let Some(color) = entry.as_str().filter(|c| is_edit_color(c)) else {
            diagnostics.push(diagnostic(&at, "expected \"#RRGGBB\""));
            continue;
        };
        colors
            .entry(name.to_owned())
            .or_default()
            .insert(token.to_owned(), json!(color.to_lowercase()));
    }
    Ok(json!({"colors": colors, "diagnostics": diagnostics}))
}

fn dictation_shortcut(request: &Value) -> Result<Value, OpError> {
    let text = string(request, "text")?.to_lowercase();
    let parts: Vec<&str> = text.split('+').map(trim_whitespaces).collect();
    let is_key = |key: &str| {
        if ["space", "return", "tab"].contains(&key) {
            return true;
        }
        let mut chars = key.chars();
        if let (Some(c), None) = (chars.next(), chars.next()) {
            return c.is_ascii_alphanumeric();
        }
        key.strip_prefix('f')
            .and_then(|n| n.parse::<i64>().ok())
            .is_some_and(|n| (1..=19).contains(&n))
    };
    let no = json!({"valid": false});
    let Some((key, mods)) =
        parts.split_last().filter(|(key, mods)| !mods.is_empty() && is_key(key))
    else {
        return Ok(no);
    };
    let mut seen: Vec<&str> = Vec::new();
    for part in mods {
        let modifier = match *part {
            "cmd" | "command" => "command",
            "ctrl" | "control" => "control",
            "opt" | "option" | "alt" => "option",
            "shift" => "shift",
            _ => return Ok(no),
        };
        if seen.contains(&modifier) {
            return Ok(no);
        }
        seen.push(modifier);
    }
    if !seen.iter().any(|m| ["command", "control", "option"].contains(m)) {
        return Ok(no);
    }
    Ok(json!({"valid": true, "modifiers": seen, "key": key}))
}

#[cfg(test)]
#[path = "section_reads_tests.rs"]
mod tests;
