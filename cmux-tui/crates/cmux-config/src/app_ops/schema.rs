//! `schema.*`: what a settings row's value means, for the app's Settings page and Command Palette
//! (Swift `SettingDescriptor+Values` and `SettingDescriptor+Palette`), on the embedded schema
//! ([`crate::schema::Schema::embedded`]). Every op takes the dotted `key` of a row.
//!
//! - `schema.stored` `{key, root, arts?}` answers `{value}`: the value `root` holds, or, when the
//!   key is absent, the old key's value as the row reads it (the retired-keys table, and
//!   `appearance.backdropArt` for `appearance.background`); null when neither is there. The art
//!   catalog is the app's: an old painting id it has not resolved yet answers `{need: {art: ID}}`,
//!   and the app asks again with `arts[ID]` = the work standing in for it, or null for none.
//! - `schema.effective` `{key, root, arts?}` answers `{value}`: the stored value when the row
//!   accepts it, else the default (null when derived at run time).
//! - `schema.accepts` `{key, value}` answers `{accepted}`: whether the app applies `value` without
//!   a diagnostic. A `json` row checks the top-level type only (the shape is the daemon's).
//! - `schema.customized` `{key, root, arts?}` answers `{customized}`: a stored value that differs
//!   from the default (the row shows Reset).
//! - `schema.toggled` `{key, root, arts?}` answers `{value}`: what a toggle flips to, null for any
//!   other kind.
//! - `schema.typed` `{key, text}` answers `{value}`: the JSON value for typed text, null when the
//!   row refuses it.
//! - `schema.inherited` `{key, root}` answers `{value}`: what a row with no value of its own goes
//!   by (a per-kind second-line order follows All Workspaces'), null for every other row.
//! - `schema.palette_options` `{key, current, inherited?, theme_colors?, selection?}` answers
//!   `{options, summary}`. An option is `{value?, title, current}` (no `value`: unset the key),
//!   with `swatch` `{theme: INDEX}` (of `theme_colors`, each `{red, green, blue, alpha}` in 0...1)
//!   or `{hex}` for a color. A title is a catalog text `{text, key}`, a number
//!   `{number, unit}` the app formats, or `{format: TEXT, arg: TEXT}` (`Move %@ to Front`).
//!   `summary` is null or the titles the row's value text joins with ", ". The background row
//!   names a value it does not list by the app's resolution of it: `selection` `{id, title}`, or
//!   null when it is no background; missing, the op answers `{need: {selection: VALUE}}`.
//! - `schema.palette_rows` `{developer_tools}` answers `{keys}`: the rows the Command Palette
//!   lists, in schema order.

use std::sync::OnceLock;

use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::domains::Domains;
use crate::schema::{Choice, Kind, NumberRange, Row, Schema, Text};
use crate::text::trim_whitespaces;
use crate::value::{number_value, value_at};

/// `appearance.background` (Swift `BackdropSelectionSetting.configPath`).
const BACKGROUND: &str = "appearance.background";
/// The paintings-only key `appearance.background` replaced (Swift `BackdropArtSetting`).
const BACKDROP_ART: &str = "appearance.backdropArt";
/// The pinned tab bar buttons (Swift `PaneToolbarButtonsSetting.configPath`): an ordered list of
/// what shows, so a choice it leaves out is hidden.
const PANE_TOOLBAR_BUTTONS: &str = "tabs.toolbarButtons";
/// Swift `AgentPaneDisplaySettingsSchema.minimapKey`: an old `true` reads as `full`.
const MINIMAP: &str = "agentPane.display.minimap";
/// Swift `WorkspaceRowSetting.root` and `orderKey`; the per-kind orders follow the root's.
const WORKSPACE_ROW: [&str; 2] = ["sidebar", "workspaceRow"];
const SECOND_LINE_ORDER: &str = "secondLineOrder";
const WORKSPACE_ROW_KINDS: [&str; 4] = ["terminal", "agent", "browser", "mixed"];
/// Settings > Development: listed only in builds with developer tools.
const DEVELOPMENT: &str = "development";
/// Most values a number lists; a wider range is sampled on its step grid.
const MAXIMUM_NUMBER_OPTIONS: usize = 41;

/// Runs a `schema.*` op; `None` when `op` is not one.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "schema.stored" => row(request).and_then(|row| {
            Ok(match stored(row, root(request), arts(request)?) {
                Read::Value(value) => json!({ "value": value }),
                Read::Need(need) => json!({ "need": need }),
            })
        }),
        "schema.effective" => row(request).and_then(|row| {
            Ok(match effective(row, root(request), arts(request)?) {
                Read::Value(value) => json!({ "value": value }),
                Read::Need(need) => json!({ "need": need }),
            })
        }),
        "schema.accepts" => row(request).and_then(|row| {
            let value = request
                .get("value")
                .ok_or_else(|| OpError::Invalid("expected a `value`".to_owned()))?;
            Ok(json!({ "accepted": accepts(row, value) }))
        }),
        "schema.customized" => row(request).and_then(|row| {
            Ok(match stored(row, root(request), arts(request)?) {
                Read::Value(value) => json!({ "customized": is_customized(row, value.as_ref()) }),
                Read::Need(need) => json!({ "need": need }),
            })
        }),
        "schema.toggled" => row(request).and_then(|row| {
            Ok(match effective(row, root(request), arts(request)?) {
                Read::Value(value) => json!({ "value": toggled(row, value.as_ref()) }),
                Read::Need(need) => json!({ "need": need }),
            })
        }),
        "schema.typed" => row(request)
            .and_then(|row| Ok(json!({ "value": typed(row, string(request, "text")?) }))),
        "schema.inherited" => {
            row(request).map(|row| json!({ "value": inherited(row, root(request)) }))
        }
        "schema.palette_options" => row(request).and_then(|row| palette_options_op(row, request)),
        "schema.palette_rows" => {
            let developer_tools =
                request.get("developer_tools").and_then(Value::as_bool).unwrap_or(false);
            Ok(json!({ "keys": palette_rows(developer_tools) }))
        }
        _ => return None,
    })
}

/// The row named by the request's `key`.
fn row(request: &Value) -> Result<&'static Row, OpError> {
    let key = string(request, "key")?;
    Schema::embedded().row(key).ok_or_else(|| OpError::Invalid(format!("no setting `{key}`")))
}

fn root(request: &Value) -> &Value {
    request.get("root").unwrap_or(&Value::Null)
}

/// The app's resolutions of old painting ids: id -> the work standing in for it, or null.
fn arts(request: &Value) -> Result<&Map<String, Value>, OpError> {
    static EMPTY: OnceLock<Map<String, Value>> = OnceLock::new();
    match request.get("arts") {
        None | Some(Value::Null) => Ok(EMPTY.get_or_init(Map::new)),
        Some(Value::Object(arts)) => Ok(arts),
        Some(_) => Err(OpError::Invalid("expected an object `arts`".to_owned())),
    }
}

/// A read, or what only the app can answer first.
#[derive(Debug, Clone, PartialEq)]
pub enum Read {
    Value(Option<Value>),
    Need(Value),
}

/// Swift `JSONValue` equality: every number is a double, so `1` and `1.0` are equal.
pub fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len() && a.iter().all(|(key, a)| b.get(key).is_some_and(|b| same(a, b)))
        }
        _ => a == b,
    }
}

fn same_option(a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => same(a, b),
        (None, None) => true,
        _ => false,
    }
}

/// Swift `SettingDescriptor.storedValue(in:)`: the value at the row's key, else the old key's
/// value as the row reads it (Swift `RenamedSettingKeys.legacyValue`).
pub fn stored(row: &Row, root: &Value, arts: &Map<String, Value>) -> Read {
    if let Some(value) = value_at(root, &row.path) {
        return Read::Value(Some(value.clone()));
    }
    if let Some(replaced) = crate::schema::replaced_by_row(&row.path) {
        // As the retired-keys table maps it; any other old value is the row's default. A plain
        // rename (no `values`) reads the old value as is.
        return Read::Value(
            value_at(root, &replaced.old).and_then(|old| replaced.read(old)).cloned(),
        );
    }
    if row.key != BACKGROUND {
        return Read::Value(None);
    }
    let Some(old) = value_at(root, &BACKDROP_ART.split('.').collect::<Vec<_>>()) else {
        return Read::Value(None);
    };
    // As `BackdropArtSetting` parses it: a bundled work (a retired id names its stand-in), else
    // nothing is painted, which the background row calls none.
    let none = || Value::String("none".to_owned());
    let Some(id) = old.as_str() else { return Read::Value(Some(none())) };
    if id != "none" && is_backdrop_art(id) {
        return Read::Value(Some(Value::String(id.to_owned())));
    }
    match arts.get(id) {
        Some(Value::String(work)) => Read::Value(Some(Value::String(work.clone()))),
        Some(_) => Read::Value(Some(none())),
        None if id == "none" => Read::Value(Some(none())),
        None => Read::Need(json!({ "art": id })),
    }
}

/// A painting of `appearance.backdropArt` (Swift `BackdropArt(rawValue:)`): one of its choices
/// after None.
fn is_backdrop_art(id: &str) -> bool {
    match Schema::embedded().row(BACKDROP_ART).map(|row| &row.kind) {
        Some(Kind::Choice(choices)) => choices.iter().any(|choice| choice.value == id),
        _ => false,
    }
}

/// Swift `SettingDescriptor.effectiveValue(in:)`: the stored value when the row accepts it, else
/// the default (what the app applies: a bad value keeps the default, with a diagnostic).
pub fn effective(row: &Row, root: &Value, arts: &Map<String, Value>) -> Read {
    match stored(row, root, arts) {
        Read::Value(Some(stored)) => match page_value(row, stored) {
            Some(value) if accepts(row, &value) => Read::Value(Some(value)),
            _ => Read::Value(row.default.clone()),
        },
        Read::Value(None) => Read::Value(row.default.clone()),
        need => need,
    }
}

/// Swift `AgentPaneDisplaySettingsSchema.pageValue`: the minimap's old switch, `true` as `full`
/// and `false` as none.
fn page_value(row: &Row, value: Value) -> Option<Value> {
    match value {
        Value::Bool(on) if row.key == MINIMAP => on.then(|| Value::String("full".to_owned())),
        value => Some(value),
    }
}

/// Swift `SettingDescriptor.accepts`: whether the app applies `value` without a diagnostic.
/// Numbers outside the range are refused, although the parser clamps them, so the window never
/// writes a value that loads with a warning. A `json` row checks the top-level type only: its
/// shape and domain are the daemon's, so a value the daemon wrote is never dropped here.
pub fn accepts(row: &Row, value: &Value) -> bool {
    if let Kind::Json(shape) = &row.kind {
        return match shape.get("type").and_then(Value::as_str) {
            Some("array") => value.is_array(),
            Some("object") => value.is_object(),
            _ => true,
        };
    }
    crate::schema::accepts(row, value, &Domains::default()).is_ok()
}

/// Swift `SettingDescriptor.isCustomized(in:)`: a stored value that differs from the default.
pub fn is_customized(row: &Row, stored: Option<&Value>) -> bool {
    stored.is_some_and(|stored| !same_option(Some(stored), row.default.as_ref()))
}

/// Swift `SettingDescriptor.toggledValue(in:)`: the opposite of what applies now, so a setting
/// whose default is on turns off on its first toggle; `None` for a row that is no toggle.
pub fn toggled(row: &Row, effective: Option<&Value>) -> Option<bool> {
    matches!(row.kind, Kind::Toggle).then(|| !effective.and_then(Value::as_bool).unwrap_or(false))
}

/// Swift `Double(text)`: a decimal number, an exponent, `inf` or `nan`.
fn parse_double(text: &str) -> Option<f64> {
    let lower = text.to_ascii_lowercase();
    let body = lower.strip_prefix(['+', '-']).unwrap_or(&lower);
    let named = matches!(body, "inf" | "infinity" | "nan");
    let decimal = !body.is_empty()
        && body.chars().all(|c| c.is_ascii_digit() || matches!(c, '.' | 'e' | '+' | '-'));
    if named || decimal { text.parse().ok() } else { None }
}

/// Swift `SettingDescriptor.value(typed:)`: the JSON value for typed text (a number off the
/// steps, a hex color, a font, a sound, an address), when the row accepts it.
pub fn typed(row: &Row, text: &str) -> Option<Value> {
    let trimmed = trim_whitespaces(text);
    let candidate = match &row.kind {
        Kind::Number(_) | Kind::ChoiceOrNumber(..) => match parse_double(trimmed) {
            // A non-finite number is no JSON number: refused either way.
            Some(x) if x.is_finite() => number_value(x),
            Some(_) => return None,
            None => Value::String(trimmed.to_owned()),
        },
        // A typed address is the object form (`{"selfHosted": url}`); a choice stays its string.
        Kind::ChoiceOrUrl(choices, url_key) => {
            if has_choice(choices, trimmed) {
                Value::String(trimmed.to_owned())
            } else {
                let mut object = Map::new();
                object.insert(url_key.clone(), Value::String(trimmed.to_owned()));
                Value::Object(object)
            }
        }
        _ => Value::String(trimmed.to_owned()),
    };
    accepts(row, &candidate).then_some(candidate)
}

/// Swift `SettingDescriptor.inheritedValue(in:)`: a per-kind second-line order
/// (`sidebar.workspaceRow.terminal.secondLineOrder`) goes by All Workspaces'.
pub fn inherited(row: &Row, root: &Value) -> Option<Value> {
    let is_kind_order = row.path.len() == 4
        && row.path[..2] == WORKSPACE_ROW
        && WORKSPACE_ROW_KINDS.contains(&row.path[2].as_str())
        && row.path[3] == SECOND_LINE_ORDER;
    if !is_kind_order {
        return None;
    }
    let from =
        Schema::embedded().row(&format!("{}.{SECOND_LINE_ORDER}", WORKSPACE_ROW.join(".")))?;
    match effective(from, root, &Map::new()) {
        Read::Value(value) => value,
        Read::Need(_) => None,
    }
}

fn has_choice(choices: &[Choice], text: &str) -> bool {
    choices.iter().any(|choice| choice.value == text)
}

// MARK: palette

/// A palette option's title: a catalog text, a number the app formats, or a format with one
/// argument.
#[derive(Debug, Clone, PartialEq)]
pub enum Title {
    Text(Text),
    Number { number: f64, unit: String },
    Format { format: Text, arg: Text },
}

impl Title {
    fn to_json(&self) -> Value {
        match self {
            Title::Text(text) => json!(text),
            Title::Number { number, unit } => {
                json!({ "number": number_value(*number), "unit": unit })
            }
            Title::Format { format, arg } => json!({ "format": format, "arg": arg }),
        }
    }
}

/// A color option's swatch: a theme color by its index, or a color of its own.
#[derive(Debug, Clone, PartialEq)]
pub enum Swatch {
    Theme(usize),
    Hex(String),
}

/// One value the palette offers for a setting (Swift `SettingOption`): `value` `None` resets the
/// key to its default.
#[derive(Debug, Clone, PartialEq)]
pub struct PaletteOption {
    pub value: Option<Value>,
    pub title: Title,
    pub swatch: Option<Swatch>,
    pub current: bool,
}

impl PaletteOption {
    fn new(value: Option<Value>, title: Title, current: bool) -> Self {
        PaletteOption { value, title, swatch: None, current }
    }

    fn to_json(&self) -> Value {
        let mut object = Map::new();
        if let Some(value) = &self.value {
            object.insert("value".to_owned(), value.clone());
        }
        object.insert("title".to_owned(), self.title.to_json());
        match &self.swatch {
            Some(Swatch::Theme(index)) => {
                object.insert("swatch".to_owned(), json!({ "theme": index }));
            }
            Some(Swatch::Hex(hex)) => {
                object.insert("swatch".to_owned(), json!({ "hex": hex }));
            }
            None => {}
        }
        object.insert("current".to_owned(), Value::Bool(self.current));
        Value::Object(object)
    }
}

/// A color as the app's `ThemeRGB` holds it: components from 0 to 1.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

impl Rgba {
    /// Swift `ThemeRGB(cssHex:)`: `#RGB`, `#RRGGBB` or `#RRGGBBAA`, the `#` optional, spaces
    /// around trimmed.
    pub fn css_hex(text: &str) -> Option<Rgba> {
        let trimmed = trim_whitespaces(text);
        let digits = trimmed.strip_prefix('#').unwrap_or(trimmed);
        if ![3, 6, 8].contains(&digits.len()) || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        let mut value = u64::from_str_radix(digits, 16).ok()?;
        if digits.len() == 3 {
            let (r, g, b) = ((value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF);
            value = ((r * 17) << 16) | ((g * 17) << 8) | (b * 17);
        }
        let alpha = if digits.len() == 8 { (value & 0xFF) as f64 / 255.0 } else { 1.0 };
        if digits.len() == 8 {
            value >>= 8;
        }
        let byte = |shift: u32| ((value >> shift) & 0xFF) as f64 / 255.0;
        Some(Rgba { red: byte(16), green: byte(8), blue: byte(0), alpha })
    }

    /// Swift `SettingDescriptor.hex`: `#RRGGBB`, or `#RRGGBBAA` for a translucent color, as
    /// cmux-next.json stores it.
    pub fn hex(&self) -> String {
        let byte = |value: f64| (value * 255.0).round() as i64;
        let rgb = format!("#{:02X}{:02X}{:02X}", byte(self.red), byte(self.green), byte(self.blue));
        if self.alpha < 1.0 { format!("{rgb}{:02X}", byte(self.alpha)) } else { rgb }
    }
}

/// What the palette needs beside the row and its value.
#[derive(Debug, Clone, Default)]
pub struct PaletteContext {
    /// What a row with no value of its own goes by ([`inherited`]).
    pub inherited: Option<Value>,
    /// The theme's colors, offered as swatches for a color row.
    pub theme_colors: Vec<Rgba>,
    /// The background row's value as the app resolves it (`BackdropSelection(id:)`): `None` not
    /// asked, `Some(None)` no background.
    pub selection: Option<Option<(String, String)>>,
}

fn text(key: &str, text: &str) -> Text {
    Text { text: text.to_owned(), key: Some(key.to_owned()) }
}

fn plain(text: &str) -> Text {
    Text { text: text.to_owned(), key: None }
}

fn default_title(row: &Row) -> Title {
    Title::Text(
        row.default_label.clone().unwrap_or_else(|| text("settings.choice.default", "Default")),
    )
}

/// Swift `SettingDescriptor.paletteOptions`: the values the palette lists for this setting, the
/// current one marked: a toggle's on and off, a choice's values, a number's steps (the default
/// first), a color's theme colors as swatches (the theme default first), a list of what shows as
/// rows that toggle, a full order as rows that move a choice to the front. Kinds with free text
/// (fonts, sounds, addresses, hosts, times) list nothing; the palette types them.
/// `Err` names what the app must resolve first (the background row's value).
pub fn palette_options(
    row: &Row,
    current: Option<&Value>,
    context: &PaletteContext,
) -> Result<Vec<PaletteOption>, Value> {
    let current = current.or(row.default.as_ref());
    let current_string = current.and_then(Value::as_str);
    let choice_options = |choices: &[Choice]| -> Vec<PaletteOption> {
        choices
            .iter()
            .map(|choice| {
                PaletteOption::new(
                    Some(Value::String(choice.value.clone())),
                    Title::Text(choice.title.clone()),
                    current_string == Some(choice.value.as_str()),
                )
            })
            .collect()
    };
    Ok(match &row.kind {
        Kind::Toggle => {
            let on = current.and_then(Value::as_bool).unwrap_or(false);
            vec![
                PaletteOption::new(
                    Some(Value::Bool(true)),
                    Title::Text(text("settings.choice.on", "On")),
                    on,
                ),
                PaletteOption::new(
                    Some(Value::Bool(false)),
                    Title::Text(text("settings.choice.off", "Off")),
                    !on,
                ),
            ]
        }
        // Unset is a value of its own (`browser.hibernation`: never discard): listed first, it
        // removes the key.
        Kind::ChoiceOrNumber(choices, _) if row.default.is_none() => {
            let mut options = vec![PaletteOption::new(None, default_title(row), current.is_none())];
            options.extend(choice_options(choices));
            options
        }
        Kind::Choice(choices)
        | Kind::ChoiceOrNumber(choices, _)
        | Kind::ChoiceOrUrl(choices, _) => {
            let options = choice_options(choices);
            if row.key == BACKGROUND {
                background_options(options, current, context)?
            } else {
                options
            }
        }
        Kind::Number(number) => {
            let mut options = Vec::new();
            if row.default.is_none() {
                options.push(PaletteOption::new(None, default_title(row), current.is_none()));
            }
            let selected = current.and_then(Value::as_f64);
            options.extend(number_values(number, selected).into_iter().map(|value| {
                PaletteOption::new(
                    Some(number_value(value)),
                    Title::Number { number: value, unit: number.unit.clone() },
                    selected == Some(value),
                )
            }));
            options
        }
        Kind::Color => color_options(row, current, &context.theme_colors),
        Kind::OrderedChoices(choices) => match ordered(row) {
            None => picked_list_options(row, choices, current, false),
            Some(true) => picked_list_options(row, choices, current, true),
            Some(false) => order_options(row, choices, current, context.inherited.as_ref()),
        },
        Kind::Sound
        | Kind::Url
        | Kind::HostList
        | Kind::FolderList
        | Kind::TimeRange
        | Kind::Theme
        | Kind::FontFamily
        | Kind::Text
        | Kind::NumberList(_)
        | Kind::StringMap
        | Kind::SoundRules
        | Kind::StringList
        | Kind::Json(_) => Vec::new(),
    })
}

/// A list of choices: `None` for a choice set (Swift `choiceSet`, exported `ordered: false`),
/// else whether the ordered list holds only what shows (`tabs.toolbarButtons`, true) or is a full
/// order whose left-out choices still show after the listed ones (false).
fn ordered(row: &Row) -> Option<bool> {
    if row.raw().get("ordered").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    Some(row.key == PANE_TOOLBAR_BUTTONS)
}

/// The row that unsets a key with no default (a per-kind override: Same as All Workspaces),
/// listed first; `None` for a row with a default.
fn unset_option(row: &Row, current: Option<&Value>) -> Option<PaletteOption> {
    row.default.is_none().then(|| PaletteOption::new(None, default_title(row), current.is_none()))
}

/// The stored values that are choices, first occurrence only, in the stored order.
fn stored_choices(choices: &[Choice], value: Option<&Value>) -> Vec<String> {
    let mut stored: Vec<String> = Vec::new();
    if let Some(Value::Array(items)) = value {
        for item in items.iter().filter_map(Value::as_str) {
            if has_choice(choices, item) && !stored.iter().any(|s| s == item) {
                stored.push(item.to_owned());
            }
        }
    }
    stored
}

/// The order that applies: the stored choices, then the ones left out in the choices' order
/// (Swift `SettingDescriptor.effectiveOrder`, `WorkspaceRowElements.completeOrder`).
pub fn effective_order(choices: &[Choice], value: Option<&Value>) -> Vec<String> {
    let mut order = stored_choices(choices, value);
    for choice in choices {
        if !order.contains(&choice.value) {
            order.push(choice.value.clone());
        }
    }
    order
}

fn strings(items: &[String]) -> Value {
    Value::Array(items.iter().cloned().map(Value::String).collect())
}

/// A list of what shows (a choice set, `tabs.toolbarButtons`): one row per choice, checked while
/// the list holds it, whose value is the list with that choice toggled. A choice set keeps the
/// choices' order; an ordered one lists its stored order first, adds a choice at the end and
/// removes one in place.
fn picked_list_options(
    row: &Row,
    choices: &[Choice],
    current: Option<&Value>,
    ordered: bool,
) -> Vec<PaletteOption> {
    let stored = stored_choices(choices, current);
    let rows: Vec<&Choice> = if ordered {
        stored
            .iter()
            .filter_map(|item| choices.iter().find(|choice| &choice.value == item))
            .chain(choices.iter().filter(|choice| !stored.contains(&choice.value)))
            .collect()
    } else {
        choices.iter().collect()
    };
    let mut options: Vec<PaletteOption> = unset_option(row, current).into_iter().collect();
    options.extend(rows.into_iter().map(|choice| {
        let is_on = stored.contains(&choice.value);
        let next: Vec<String> = if ordered {
            if is_on {
                stored.iter().filter(|item| **item != choice.value).cloned().collect()
            } else {
                stored.iter().cloned().chain([choice.value.clone()]).collect()
            }
        } else {
            choices
                .iter()
                .map(|c| &c.value)
                .filter(
                    |value| if **value == choice.value { !is_on } else { stored.contains(value) },
                )
                .cloned()
                .collect()
        };
        PaletteOption::new(Some(strings(&next)), Title::Text(choice.title.clone()), is_on)
    }));
    options
}

fn choice_title(choices: &[Choice], value: &str) -> Text {
    choices
        .iter()
        .find(|choice| choice.value == value)
        .map_or_else(|| plain(value), |c| c.title.clone())
}

/// A full order (`sidebar.workspaceRow.secondLineOrder`): every choice once, in the order that
/// applies, unchecked; each row moves its choice to the front and writes the whole order. A key
/// with no value of its own starts from what it goes by (`inherited`), then the choices' order.
fn order_options(
    row: &Row,
    choices: &[Choice],
    current: Option<&Value>,
    inherited: Option<&Value>,
) -> Vec<PaletteOption> {
    let order = effective_order(choices, current.or(inherited));
    let mut options: Vec<PaletteOption> = unset_option(row, current).into_iter().collect();
    options.extend(order.iter().map(|item| {
        let moved: Vec<String> = std::iter::once(item.clone())
            .chain(order.iter().filter(|other| *other != item).cloned())
            .collect();
        let title = Title::Format {
            format: text("settings.palette.moveToFront", "Move %@ to Front"),
            arg: choice_title(choices, item),
        };
        PaletteOption::new(Some(strings(&moved)), title, false)
    }));
    options
}

/// A color's options: the theme default first, then each theme color once, then the stored color
/// when the theme has no such color.
fn color_options(row: &Row, current: Option<&Value>, theme_colors: &[Rgba]) -> Vec<PaletteOption> {
    let selected = current.and_then(Value::as_str).and_then(Rgba::css_hex);
    let selected_hex = selected.map(|color| color.hex());
    let theme =
        row.default_label.clone().unwrap_or_else(|| text("settings.default.theme", "Theme"));
    let mut options = vec![PaletteOption::new(None, Title::Text(theme), selected.is_none())];
    let mut seen: Vec<String> = Vec::new();
    for (index, color) in theme_colors.iter().enumerate() {
        let hex = color.hex();
        if seen.contains(&hex) {
            continue;
        }
        seen.push(hex.clone());
        let mut option = PaletteOption::new(
            Some(Value::String(hex.clone())),
            Title::Text(plain(&hex)),
            selected_hex.as_deref() == Some(hex.as_str()),
        );
        option.swatch = Some(Swatch::Theme(index));
        options.push(option);
    }
    if let Some(hex) = selected_hex
        && !seen.contains(&hex)
    {
        let raw = current.and_then(Value::as_str).map_or_else(|| hex.clone(), str::to_owned);
        let mut option =
            PaletteOption::new(Some(Value::String(raw.clone())), Title::Text(plain(&raw)), true);
        option.swatch = Some(Swatch::Hex(hex));
        options.push(option);
    }
    options
}

/// Swift `SettingDescriptor.backgroundOptions`: `appearance.background`'s options, naming what the
/// window shows when the value is not one the list offers: a retired painting id marks the work
/// that replaced it, and your own image or a macOS wallpaper is one more option, current, by its
/// name.
fn background_options(
    options: Vec<PaletteOption>,
    current: Option<&Value>,
    context: &PaletteContext,
) -> Result<Vec<PaletteOption>, Value> {
    let Some(raw) = current.and_then(Value::as_str) else { return Ok(options) };
    if options.iter().any(|option| option.current) {
        return Ok(options);
    }
    let Some((id, title)) = (match &context.selection {
        None => return Err(json!({ "selection": raw })),
        Some(selection) => selection.clone(),
    }) else {
        return Ok(options);
    };
    let shown = Value::String(id);
    if options.iter().any(|option| option.value.as_ref() == Some(&shown)) {
        return Ok(options
            .into_iter()
            .map(|option| {
                let current = option.value.as_ref() == Some(&shown);
                PaletteOption { current, ..option }
            })
            .collect());
    }
    let mut options = options;
    options.push(PaletteOption::new(
        Some(Value::String(raw.to_owned())),
        Title::Text(plain(&title)),
        true,
    ));
    Ok(options)
}

/// Swift `SettingDescriptor.numberValues`: every step from the low end to the high end, or, for a
/// wider range, both ends, `including` and evenly spread steps (all on the grid).
pub fn number_values(number: &NumberRange, including: Option<f64>) -> Vec<f64> {
    let (low, high) = (number.min, number.max);
    let count = ((high - low) / number.step).floor() as i64 + 1;
    let on_grid = |index: i64| high.min(low + index as f64 * number.step);
    let mut values: Vec<f64> = if count <= MAXIMUM_NUMBER_OPTIONS as i64 {
        (0..count).map(on_grid).collect()
    } else {
        let slots = (MAXIMUM_NUMBER_OPTIONS - 3) as i64;
        (0..=slots)
            .map(|slot| on_grid((slot as f64 * (count - 1) as f64 / slots as f64).round() as i64))
            .collect()
    };
    values.push(high);
    if let Some(value) = including
        && low <= value
        && value <= high
    {
        values.push(value);
    }
    values.sort_by(f64::total_cmp);
    values.dedup_by(|a, b| a == b);
    values
}

/// Swift `SettingDescriptor.paletteSummary`: the palette row's value text for a list of choices;
/// `None` for any other kind, and for a key left unset (the unset row's title says it). A list of
/// what shows names the choices it holds, or None; a full order names every choice in the order
/// that applies.
pub fn palette_summary(
    row: &Row,
    current: Option<&Value>,
    options: &[PaletteOption],
) -> Option<Vec<Text>> {
    if options.iter().any(|option| option.value.is_none() && option.current) {
        return None;
    }
    let Kind::OrderedChoices(choices) = &row.kind else { return None };
    if ordered(row) == Some(false) {
        let order = effective_order(choices, current.or(row.default.as_ref()));
        return Some(order.iter().map(|item| choice_title(choices, item)).collect());
    }
    let titles: Vec<Text> = options
        .iter()
        .filter(|option| option.value.is_some() && option.current)
        .filter_map(|option| match &option.title {
            Title::Text(text) => Some(text.clone()),
            _ => None,
        })
        .collect();
    Some(if titles.is_empty() { vec![text("settings.choice.none", "None")] } else { titles })
}

fn palette_options_op(row: &Row, request: &Value) -> Result<Value, OpError> {
    let current = request.get("current").filter(|value| !value.is_null());
    let inherited = request.get("inherited").filter(|value| !value.is_null()).cloned();
    let theme_colors = match request.get("theme_colors") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                let component = |name: &str| item.get(name).and_then(Value::as_f64);
                Some(Rgba {
                    red: component("red")?,
                    green: component("green")?,
                    blue: component("blue")?,
                    alpha: component("alpha").unwrap_or(1.0),
                })
            })
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| {
                OpError::Invalid("expected `theme_colors` of {red, green, blue, alpha}".to_owned())
            })?,
        Some(_) => return Err(OpError::Invalid("expected an array `theme_colors`".to_owned())),
    };
    let selection = match request.get("selection") {
        None => None,
        Some(Value::Null) => Some(None),
        Some(selection) => {
            let id = selection.get("id").and_then(Value::as_str);
            let title = selection.get("title").and_then(Value::as_str);
            match (id, title) {
                (Some(id), Some(title)) => Some(Some((id.to_owned(), title.to_owned()))),
                _ => {
                    return Err(OpError::Invalid(
                        "expected `selection` {id, title} or null".to_owned(),
                    ));
                }
            }
        }
    };
    let context = PaletteContext { inherited, theme_colors, selection };
    Ok(match palette_options(row, current, &context) {
        Ok(options) => {
            let summary = palette_summary(row, current, &options);
            json!({
                "options": options.iter().map(PaletteOption::to_json).collect::<Vec<_>>(),
                "summary": summary,
            })
        }
        Err(need) => json!({ "need": need }),
    })
}

/// Swift `SettingDescriptor.isPaletteListed(developerTools:)`: the rows the palette offers (the
/// export's `surfaces.palette.offered`: exposed and read by cmux-next), Settings > Development
/// only with developer tools.
pub fn palette_rows(developer_tools: bool) -> Vec<&'static str> {
    static OFFERED: OnceLock<Vec<(&'static str, bool)>> = OnceLock::new();
    let offered = OFFERED.get_or_init(|| {
        Schema::embedded()
            .rows
            .iter()
            .filter(|row| {
                row.raw().pointer("/surfaces/palette/offered").and_then(Value::as_bool)
                    == Some(true)
            })
            .map(|row| (row.key.as_str(), row.section == DEVELOPMENT))
            .collect()
    });
    offered
        .iter()
        .filter(|(_, development)| developer_tools || !development)
        .map(|(key, _)| *key)
        .collect()
}

#[cfg(test)]
#[path = "schema_tests.rs"]
mod tests;
