//! Everything a person or an agent can customize, from this build's own
//! tables: `cmux customize schema` (and the `customize_schema` MCP tool)
//! prints it, and the extension SDK's TypeScript and Rust types are written
//! from it ([`typescript`], [`rust`]), so nobody guesses a key.
//!
//! Nothing here restates a key. Each part is read from the table its owner
//! already validates with:
//! - settings: the embedded settings schema (`cmux_config::Schema`, exported
//!   from Swift), each row with its JSON Schema as `cmux settings schema`
//!   writes it;
//! - theme files: the keys a theme file reads besides look settings
//!   (`cmux_config::theme_file`) and its `colors` (the theme file JSON Schema);
//! - theme tokens: the chrome tokens and their formulas (`design-tokens.json`,
//!   as `cmux_theme_tokens` compiles it in);
//! - view slots and extension points: the interfaces this cmux knows
//!   (`cmux_app_manifest::interface_files`). A view slot is an interface whose
//!   `render` draws a scene; its places are the values of its placement option.

use cmux_config::schema::{Kind, Row, Schema as Settings};
use cmux_config::theme_file;
use serde::Serialize;
use serde_json::{Map, Value, json};

/// The shape of [`Schema`]'s JSON; a reader that knows 1 reads every 1.
pub const FORMAT: u32 = 1;

/// Everything customizable, in the order the tables list it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Schema {
    pub format: u32,
    /// The settings schema's hash (`x-cmux-schema-hash` of `cmux settings schema`).
    pub settings_hash: String,
    pub settings: Vec<Setting>,
    pub theme: Theme,
    pub views: Vec<ViewSlot>,
    pub extension_points: Vec<ExtensionPoint>,
}

/// One setting key of `cmux-next.json`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Setting {
    pub key: String,
    pub section: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// The settings export's kind name (`toggle`, `choice`, `number`, ...).
    pub kind: &'static str,
    /// The values a choice takes, in order.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub choices: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<Range>,
    /// The value an absent key means; null when it is worked out at run time.
    pub default: Option<Value>,
    /// Whether an agent may set it (`cmux settings set`, the MCP settings tools).
    pub agent_settable: bool,
    /// Whether a theme file (`themes/NAME.json`) may set it.
    pub theme_file: bool,
    /// The value's JSON Schema, as `cmux settings schema` writes it (title,
    /// description and default are the fields above).
    pub schema: Value,
}

/// A number's range.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Range {
    pub min: f64,
    pub max: f64,
    pub step: f64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub unit: String,
}

/// What a theme file holds besides look settings, and the tokens a theme derives.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Theme {
    /// The setting that picks the theme file.
    pub file_setting: &'static str,
    /// `<config dir>/themes`.
    pub folder: &'static str,
    /// Keys a theme file reads that are not settings.
    pub file_keys: Vec<String>,
    /// The members of a theme file's `colors`.
    pub colors: Vec<String>,
    /// The chrome tokens every theme derives (read-only: change the colors
    /// and settings they derive from).
    pub tokens: Vec<Token>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Token {
    pub name: String,
    /// How it derives (`alpha(bg, 0.04)`, `= windowBackground`, or prose).
    pub formula: String,
}

/// A place a view can be drawn.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ViewSlot {
    /// The interface a view implements to fill it (`cmux.section/1`).
    pub interface: String,
    pub docs: String,
    /// The option that picks the place, when there is a choice.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub place_option: Option<String>,
    /// Its values, in order.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub places: Vec<String>,
}

/// An interface an extension implements (`implements` in `cmux-app.json`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ExtensionPoint {
    pub interface: String,
    pub docs: String,
    /// Method name to its shape, as the interface file says it.
    pub methods: Map<String, Value>,
    /// The JSON Schema of the options it takes; null when it takes none.
    pub options: Option<Value>,
    /// Whether it draws a view (it is also a view slot).
    pub view: bool,
}

/// One part of the schema, for `cmux customize schema PART`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Section {
    Settings,
    Theme,
    Views,
    ExtensionPoints,
}

impl Section {
    pub const NAMES: &'static str = "settings, theme, views or extensions";

    pub fn parse(word: &str) -> Option<Section> {
        Some(match word {
            "settings" | "setting" => Section::Settings,
            "theme" | "themes" | "tokens" => Section::Theme,
            "views" | "view" | "slots" => Section::Views,
            "extensions" | "extension" | "extension-points" | "interfaces" => {
                Section::ExtensionPoints
            }
            _ => return None,
        })
    }
}

impl Schema {
    /// The schema of this build.
    pub fn current() -> Schema {
        let settings = Settings::embedded();
        let tree = settings.json_schema();
        let theme_file_schema = settings.theme_file_json_schema(theme_file::is_look);
        let files = cmux_app_manifest::interface_files();
        let documents: Vec<(&str, Value)> = files
            .iter()
            .map(|(name, text)| (*name, serde_json::from_str(text).unwrap_or(Value::Null)))
            .collect();
        Schema {
            format: FORMAT,
            settings_hash: settings.schema_hash.clone(),
            settings: settings.rows.iter().map(|row| setting(row, &tree)).collect(),
            theme: Theme {
                file_setting: theme_file::SETTING_KEY,
                folder: theme_file::FOLDER_NAME,
                file_keys: theme_file::RESERVED_KEYS.iter().map(|key| (*key).to_owned()).collect(),
                colors: theme_file_schema
                    .pointer("/properties/colors/properties")
                    .and_then(Value::as_object)
                    .map(|colors| colors.keys().cloned().collect())
                    .unwrap_or_default(),
                tokens: tokens(cmux_theme_tokens::DESIGN_TOKENS),
            },
            views: documents.iter().filter_map(|(name, file)| view_slot(name, file)).collect(),
            extension_points: documents
                .iter()
                .map(|(name, file)| ExtensionPoint {
                    interface: (*name).to_owned(),
                    docs: text_at(file, "docs"),
                    methods: file
                        .get("methods")
                        .and_then(Value::as_object)
                        .cloned()
                        .unwrap_or_default(),
                    options: file.get("options").cloned(),
                    view: draws_a_view(file),
                })
                .collect(),
        }
    }

    /// The JSON an agent reads: the whole schema, or one part of it.
    pub fn to_json(&self, only: Option<Section>) -> Value {
        let all = serde_json::to_value(self).unwrap_or(Value::Null);
        let Some(section) = only else { return all };
        let member = match section {
            Section::Settings => "settings",
            Section::Theme => "theme",
            Section::Views => "views",
            Section::ExtensionPoints => "extension_points",
        };
        let mut out = Map::new();
        out.insert("format".to_owned(), json!(self.format));
        if section == Section::Settings {
            out.insert("settings_hash".to_owned(), json!(self.settings_hash));
        }
        out.insert(member.to_owned(), all.get(member).cloned().unwrap_or(Value::Null));
        Value::Object(out)
    }

    pub fn setting(&self, key: &str) -> Option<&Setting> {
        self.settings.iter().find(|setting| setting.key == key)
    }
}

fn setting(row: &Row, tree: &Value) -> Setting {
    let (choices, range) = match &row.kind {
        Kind::Choice(choices) | Kind::OrderedChoices(choices) | Kind::ChoiceOrUrl(choices, _) => {
            (choices.iter().map(|c| c.value.clone()).collect(), None)
        }
        Kind::ChoiceOrNumber(choices, range) => {
            (choices.iter().map(|c| c.value.clone()).collect(), Some(range))
        }
        Kind::Number(range) | Kind::NumberList(range) => (Vec::new(), Some(range)),
        _ => (Vec::new(), None),
    };
    let mut schema = row
        .path
        .iter()
        .enumerate()
        .try_fold(tree, |node, (depth, part)| {
            let node = node.get("properties")?.get(part)?;
            // A leaf is the row's own; an object on the way is a parent.
            (depth + 1 < row.path.len() || node.get("x-cmux-key").is_some()).then_some(node)
        })
        .cloned()
        .unwrap_or(Value::Null);
    if let Value::Object(members) = &mut schema {
        for said_above in [
            "title",
            "description",
            "default",
            "x-cmux-key",
            "x-cmux-section",
            "x-cmux-agent-settable",
        ] {
            members.remove(said_above);
        }
    }
    Setting {
        key: row.key.clone(),
        section: row.section.clone(),
        title: row.title.text.clone(),
        summary: row.summary.as_ref().map(|text| text.text.clone()),
        kind: row.kind.name(),
        choices,
        range: range.map(|range| Range {
            min: range.min,
            max: range.max,
            step: range.step,
            unit: range.unit.clone(),
        }),
        default: row.default.clone(),
        agent_settable: row.agent_settable,
        theme_file: theme_file::is_look(row),
        schema,
    }
}

/// `theme.formulas` of `design-tokens.json`: each token and its formula.
fn tokens(design_tokens: &str) -> Vec<Token> {
    let parsed: Value = serde_json::from_str(design_tokens).unwrap_or(Value::Null);
    let Some(formulas) = parsed.pointer("/theme/formulas").and_then(Value::as_object) else {
        return Vec::new();
    };
    formulas
        .iter()
        .map(|(name, formula)| Token {
            name: name.clone(),
            formula: formula
                .get("value")
                .and_then(Value::as_str)
                .or_else(|| formula.as_str())
                .unwrap_or_default()
                .to_owned(),
        })
        .collect()
}

fn text_at(file: &Value, key: &str) -> String {
    file.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// Whether the interface's `render` can draw a scene (a view cmux lays out).
fn draws_a_view(file: &Value) -> bool {
    file.pointer("/methods/render")
        .and_then(Value::as_str)
        .is_some_and(|shapes| shapes.split('|').any(|shape| shape.trim() == "scene"))
}

/// The options whose values say where a view goes.
const PLACE_OPTIONS: [&str; 2] = ["defaultRegion", "placement"];

fn view_slot(name: &str, file: &Value) -> Option<ViewSlot> {
    if !draws_a_view(file) {
        return None;
    }
    let place = PLACE_OPTIONS.iter().find_map(|option| {
        let values = file.pointer(&format!("/options/properties/{option}/enum"))?.as_array()?;
        Some((
            (*option).to_owned(),
            values.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>(),
        ))
    });
    let (place_option, places) = place.map_or((None, Vec::new()), |(o, p)| (Some(o), p));
    Some(ViewSlot { interface: name.to_owned(), docs: text_at(file, "docs"), place_option, places })
}

// ---------------------------------------------------------------------------
// The SDK's types, written from the schema.

/// The header both generated files start with.
fn generated_header(comment: &str, schema: &Schema) -> String {
    format!(
        "{comment} GENERATED by cmux_customize::schema from this cmux's own tables (settings schema \
{hash}). Do not edit:\n{comment} regenerate with `cmux customize schema --typescript` / `--rust`, \
or build cmux-extension-sdk.\n",
        hash = short(&schema.settings_hash),
    )
}

fn short(hash: &str) -> &str {
    hash.get(..12).unwrap_or(hash)
}

/// One line of doc text: no line breaks, no comment terminators.
fn doc_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ").replace("*/", "* /")
}

fn quoted(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_owned())
}

/// The TypeScript types of the schema (`cmux-extension-sdk/customize`):
/// types only, so an `import type` of them adds nothing to a bundle.
pub fn typescript(schema: &Schema) -> String {
    let mut out = generated_header("//", schema);
    out.push_str(
        "\n/** Every cmux setting key (cmux-next.json, dotted) and the value it holds. */\n",
    );
    out.push_str("export interface CmuxSettings {\n");
    for setting in &schema.settings {
        let mut doc = doc_line(&setting.title);
        if let Some(summary) = &setting.summary {
            doc.push_str(&format!(". {}", doc_line(summary)));
        }
        if let Some(default) = &setting.default {
            doc.push_str(&format!(" Default: `{}`.", doc_line(&default.to_string())));
        }
        if !setting.agent_settable {
            doc.push_str(" Only the person sets it.");
        }
        out.push_str(&format!("  /** {doc} */\n"));
        out.push_str(&format!("  {}: {}\n", quoted(&setting.key), ts_type(&setting.schema)));
    }
    out.push_str("}\n");
    out.push_str("/** A setting key. */\nexport type SettingKey = keyof CmuxSettings\n");
    out.push_str("/** The value `key` holds. */\nexport type SettingValue<K extends SettingKey> = CmuxSettings[K]\n");
    let union = |names: Vec<&str>| -> String {
        if names.is_empty() {
            "never".to_owned()
        } else {
            names.iter().map(|name| quoted(name)).collect::<Vec<_>>().join(" | ")
        }
    };
    let agent = schema.settings.iter().filter(|s| s.agent_settable).map(|s| s.key.as_str());
    out.push_str(&format!(
        "/** The keys an agent may set. */\nexport type AgentSettableKey = {}\n",
        union(agent.collect())
    ));
    let look = schema.settings.iter().filter(|s| s.theme_file).map(|s| s.key.as_str());
    out.push_str(&format!(
        "/** The settings a theme file ({}/NAME.json) may set. */\nexport type ThemeFileSettingKey = {}\n",
        schema.theme.folder,
        union(look.collect())
    ));
    out.push_str(&format!(
        "/** Keys a theme file reads that are not settings. */\nexport type ThemeFileKey = {}\n",
        union(schema.theme.file_keys.iter().map(String::as_str).collect())
    ));
    out.push_str(&format!(
        "/** The members of a theme file's `colors`. */\nexport type ThemeColor = {}\n",
        union(schema.theme.colors.iter().map(String::as_str).collect())
    ));
    out.push_str("/** The chrome tokens every theme derives, and how. */\nexport interface CmuxThemeTokens {\n");
    for token in &schema.theme.tokens {
        out.push_str(&format!(
            "  /** {} */\n  {}: string\n",
            doc_line(&token.formula),
            quoted(&token.name)
        ));
    }
    out.push_str("}\nexport type ThemeToken = keyof CmuxThemeTokens\n");
    out.push_str("/** Where a view can be drawn: each view slot and the places it takes. */\nexport interface CmuxViewSlots {\n");
    for slot in &schema.views {
        out.push_str(&format!(
            "  /** {} */\n  {}: {}\n",
            doc_line(&slot.docs),
            quoted(&slot.interface),
            union(slot.places.iter().map(String::as_str).collect())
        ));
    }
    out.push_str("}\nexport type ViewSlot = keyof CmuxViewSlots\n");
    out.push_str("/** Every interface an extension implements (`implements` in cmux-app.json) and the options it takes. */\nexport interface CmuxExtensionPoints {\n");
    for point in &schema.extension_points {
        let options = point.options.as_ref().map_or_else(|| "never".to_owned(), ts_type);
        out.push_str(&format!(
            "  /** {} */\n  {}: {}\n",
            doc_line(&point.docs),
            quoted(&point.interface),
            options
        ));
    }
    out.push_str("}\nexport type ExtensionPoint = keyof CmuxExtensionPoints\n");
    out
}

/// A TypeScript type for a JSON Schema: the subset the settings and
/// interface files use. What it cannot say is `unknown`, never a guess.
fn ts_type(schema: &Value) -> String {
    let Some(members) = schema.as_object() else { return "unknown".to_owned() };
    if let Some(values) = members.get("enum").and_then(Value::as_array) {
        return union_of(values.iter().map(|value| value.to_string()));
    }
    if let Some(value) = members.get("const") {
        return value.to_string();
    }
    let types: Vec<&str> = match members.get("type") {
        Some(Value::String(one)) => vec![one.as_str()],
        Some(Value::Array(many)) => many.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    };
    if types.is_empty() {
        for any in ["anyOf", "oneOf"] {
            if let Some(options) = members.get(any).and_then(Value::as_array) {
                return union_of(options.iter().map(ts_type));
            }
        }
        return "unknown".to_owned();
    }
    union_of(types.into_iter().map(|kind| match kind {
        "boolean" => "boolean".to_owned(),
        "string" => "string".to_owned(),
        "number" | "integer" => "number".to_owned(),
        "null" => "null".to_owned(),
        "array" => {
            let items = members.get("items").map_or_else(|| "unknown".to_owned(), ts_type);
            format!("Array<{items}>")
        }
        "object" => object_type(members),
        _ => "unknown".to_owned(),
    }))
}

fn object_type(members: &Map<String, Value>) -> String {
    let required: Vec<&str> = members
        .get("required")
        .and_then(Value::as_array)
        .map(|names| names.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let properties = members.get("properties").and_then(Value::as_object);
    let rest = match members.get("additionalProperties") {
        Some(Value::Bool(false)) => None,
        Some(Value::Object(_)) => members.get("additionalProperties").map(ts_type),
        _ => Some("unknown".to_owned()),
    };
    let fields: Vec<String> = properties
        .into_iter()
        .flatten()
        .map(|(name, schema)| {
            let optional = if required.contains(&name.as_str()) { "" } else { "?" };
            format!("{}{optional}: {}", quoted(name), ts_type(schema))
        })
        .collect();
    match (fields.is_empty(), rest) {
        (true, Some(rest)) => format!("Record<string, {rest}>"),
        (true, None) => "Record<string, never>".to_owned(),
        // An index signature must admit every named field's type.
        (false, Some(_)) => format!("{{ {}; [key: string]: unknown }}", fields.join("; ")),
        (false, None) => format!("{{ {} }}", fields.join("; ")),
    }
}

fn union_of(parts: impl Iterator<Item = String>) -> String {
    let mut seen: Vec<String> = Vec::new();
    for part in parts {
        if !seen.contains(&part) {
            seen.push(part);
        }
    }
    match seen.len() {
        0 => "never".to_owned(),
        1 => seen.remove(0),
        _ => seen.join(" | "),
    }
}

/// The Rust tables of the schema (`cmux_extension_sdk::customize`): one
/// constant per setting key in `keys`, so a key that does not exist is a
/// compile error.
pub fn rust(schema: &Schema) -> String {
    let mut out = generated_header("//", schema);
    out.push_str(
        "
/// One setting key of `cmux-next.json`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Setting {
    pub key: &'static str,
    pub section: &'static str,
    pub title: &'static str,
    /// The settings export's kind name (`toggle`, `choice`, `number`, ...).
    pub kind: &'static str,
    /// The values a choice takes.
    pub choices: &'static [&'static str],
    /// `(min, max, step)` of a number.
    pub range: Option<(f64, f64, f64)>,
    /// The default as JSON text; `None` when it is worked out at run time.
    pub default: Option<&'static str>,
    pub agent_settable: bool,
    /// Whether a theme file may set it.
    pub theme_file: bool,
}

/// A chrome token every theme derives, and how.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThemeToken {
    pub name: &'static str,
    pub formula: &'static str,
}

/// A place a view can be drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ViewSlot {
    pub interface: &'static str,
    pub places: &'static [&'static str],
    pub docs: &'static str,
}

/// An interface an extension implements.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExtensionPoint {
    pub interface: &'static str,
    /// Whether it draws a view.
    pub view: bool,
    pub docs: &'static str,
}

",
    );
    out.push_str(&format!(
        "/// The settings schema these tables were written from.\npub const SETTINGS_HASH: &str = {:?};\n\n",
        schema.settings_hash
    ));
    out.push_str(
        "/// Every setting, in the settings schema's order.\npub const SETTINGS: &[Setting] = &[\n",
    );
    for setting in &schema.settings {
        let choices =
            setting.choices.iter().map(|c| format!("{c:?}")).collect::<Vec<_>>().join(", ");
        let range = setting.range.as_ref().map_or_else(
            || "None".to_owned(),
            |r| format!("Some(({:?}, {:?}, {:?}))", r.min, r.max, r.step),
        );
        let default = setting
            .default
            .as_ref()
            .map_or_else(|| "None".to_owned(), |value| format!("Some({:?})", value.to_string()));
        out.push_str(&format!(
            "    Setting {{ key: {:?}, section: {:?}, title: {:?}, kind: {:?}, choices: &[{choices}], range: {range}, default: {default}, agent_settable: {}, theme_file: {} }},\n",
            setting.key, setting.section, setting.title, setting.kind, setting.agent_settable, setting.theme_file,
        ));
    }
    out.push_str("];\n\n/// Each setting key as a constant: `keys::APPEARANCE_THEME_FILE` is `\"appearance.themeFile\"`.\npub mod keys {\n");
    for (name, key) in key_constants(&schema.settings) {
        out.push_str(&format!("    pub const {name}: &str = {key:?};\n"));
    }
    out.push_str("}\n\n");
    let list =
        |items: &[String]| items.iter().map(|i| format!("{i:?}")).collect::<Vec<_>>().join(", ");
    out.push_str(&format!(
        "/// Keys a theme file reads that are not settings.\npub const THEME_FILE_KEYS: &[&str] = &[{}];\n",
        list(&schema.theme.file_keys)
    ));
    out.push_str(&format!(
        "/// The members of a theme file's `colors`.\npub const THEME_COLORS: &[&str] = &[{}];\n",
        list(&schema.theme.colors)
    ));
    out.push_str(
        "/// The chrome tokens every theme derives.\npub const THEME_TOKENS: &[ThemeToken] = &[\n",
    );
    for token in &schema.theme.tokens {
        out.push_str(&format!(
            "    ThemeToken {{ name: {:?}, formula: {:?} }},\n",
            token.name, token.formula
        ));
    }
    out.push_str(
        "];\n/// Every place a view can be drawn.\npub const VIEW_SLOTS: &[ViewSlot] = &[\n",
    );
    for slot in &schema.views {
        out.push_str(&format!(
            "    ViewSlot {{ interface: {:?}, places: &[{}], docs: {:?} }},\n",
            slot.interface,
            list(&slot.places),
            doc_line(&slot.docs)
        ));
    }
    out.push_str("];\n/// Every interface an extension implements.\npub const EXTENSION_POINTS: &[ExtensionPoint] = &[\n");
    for point in &schema.extension_points {
        out.push_str(&format!(
            "    ExtensionPoint {{ interface: {:?}, view: {}, docs: {:?} }},\n",
            point.interface,
            point.view,
            doc_line(&point.docs)
        ));
    }
    out.push_str(
        "];\n
/// The setting `key`, if cmux has it.
pub fn setting(key: &str) -> Option<&'static Setting> {
    SETTINGS.iter().find(|setting| setting.key == key)
}
",
    );
    out
}

/// `appearance.themeFile` to `APPEARANCE_THEME_FILE`; a name two keys
/// share gets the later key's position appended, so every key has one.
pub fn key_constants(settings: &[Setting]) -> Vec<(String, &str)> {
    let mut out: Vec<(String, &str)> = Vec::new();
    for (index, setting) in settings.iter().enumerate() {
        let mut name = String::new();
        let mut previous: Option<char> = None;
        for c in setting.key.chars() {
            if c.is_ascii_uppercase()
                && previous.is_some_and(|p| p.is_ascii_lowercase() || p.is_ascii_digit())
            {
                name.push('_');
            }
            name.push(if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' });
            previous = Some(c);
        }
        if name.starts_with(|c: char| c.is_ascii_digit()) || name.is_empty() {
            name.insert(0, '_');
        }
        if out.iter().any(|(taken, _)| *taken == name) {
            name.push_str(&format!("_{index}"));
        }
        out.push((name, setting.key.as_str()));
    }
    out
}
