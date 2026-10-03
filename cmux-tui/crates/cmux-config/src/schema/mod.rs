//! The settings schema exported from Swift (`SettingsSchemaExport`,
//! `schemas/settings/settings-schema.json`), embedded at build time so a
//! bundled daemon and its app always agree.

mod accepts;
mod url;

use std::collections::HashMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use accepts::{Accepted, accepts, effective_value, is_hex_color};
pub use url::new_tab_page_url_is_valid;

use crate::value::canonical;

const EMBEDDED: &str = include_str!("../../../../../schemas/settings/settings-schema.json");

/// A text with the string catalog key it came from (nil for a product name).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Text {
    pub text: String,
    pub key: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    pub title: Text,
    pub symbol: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Choice {
    pub value: String,
    pub title: Text,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NumberRange {
    pub min: f64,
    pub max: f64,
    pub step: f64,
    pub unit: String,
    pub placeholder: f64,
}

/// What a setting holds (Swift `SettingKind`).
#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Toggle,
    Choice(Vec<Choice>),
    ChoiceOrNumber(Vec<Choice>, NumberRange),
    Number(NumberRange),
    Color,
    Sound,
    Url,
    HostList,
    TimeRange,
    Theme,
    FontFamily,
}

impl Kind {
    /// The export's name of the kind.
    pub fn name(&self) -> &'static str {
        match self {
            Kind::Toggle => "toggle",
            Kind::Choice(_) => "choice",
            Kind::ChoiceOrNumber(..) => "choice_or_number",
            Kind::Number(_) => "number",
            Kind::Color => "color",
            Kind::Sound => "sound",
            Kind::Url => "url",
            Kind::HostList => "host_list",
            Kind::TimeRange => "time_range",
            Kind::Theme => "theme",
            Kind::FontFamily => "font_family",
        }
    }
}

/// How a row is validated: a fixed rule, or the value domain the app publishes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Validation {
    Portable,
    Domain(DomainKind),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DomainKind {
    Theme,
    FontFamily,
    Sound,
}

/// One descriptor row.
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub key: String,
    pub path: Vec<String>,
    pub section: String,
    pub group: Text,
    pub title: Text,
    pub help: Option<Text>,
    pub kind: Kind,
    /// The value an absent key means; `None` when derived at run time.
    pub default: Option<Value>,
    pub default_label: Option<Text>,
    pub keywords: Vec<String>,
    pub agent_settable: bool,
    pub agent_refusal: Option<String>,
    pub kept_on_reset_all: bool,
    pub validation: Validation,
    /// Values Swift accepts / refuses (conformance samples).
    pub accepts: Vec<Value>,
    pub refuses: Vec<Value>,
    /// The row as exported (for `settings.schema` and list replies).
    pub raw: Value,
}

/// The whole schema.
#[derive(Debug)]
pub struct Schema {
    pub version: u64,
    pub schema_hash: String,
    pub sections: Vec<Section>,
    pub rows: Vec<Row>,
    by_key: HashMap<String, usize>,
    by_path: HashMap<Vec<String>, usize>,
}

#[derive(Deserialize)]
struct Document {
    version: u64,
    schema_hash: String,
    sections: Vec<Section>,
    rows: Vec<Value>,
}

#[derive(Deserialize)]
struct RawRow {
    key: String,
    path: Vec<String>,
    section: String,
    group: Text,
    title: Text,
    help: Option<Text>,
    kind: String,
    #[serde(default)]
    choices: Vec<Choice>,
    range: Option<NumberRange>,
    default: Option<Value>,
    default_label: Option<Text>,
    keywords: Vec<String>,
    agent_settable: bool,
    agent_refusal: Option<String>,
    kept_on_reset_all: bool,
    validation: String,
    accepts: Vec<Value>,
    refuses: Vec<Value>,
}

impl Schema {
    /// The schema compiled into this binary.
    pub fn embedded() -> &'static Schema {
        static SCHEMA: OnceLock<Schema> = OnceLock::new();
        SCHEMA.get_or_init(|| Schema::parse(EMBEDDED).expect("the embedded settings schema parses"))
    }

    /// Parses an export document.
    pub fn parse(text: &str) -> Result<Schema, String> {
        let document: Document = serde_json::from_str(text).map_err(|error| error.to_string())?;
        let mut rows = Vec::with_capacity(document.rows.len());
        for raw in document.rows {
            rows.push(row(raw)?);
        }
        let by_key = rows.iter().enumerate().map(|(index, row)| (row.key.clone(), index)).collect();
        let by_path =
            rows.iter().enumerate().map(|(index, row)| (row.path.clone(), index)).collect();
        Ok(Schema {
            version: document.version,
            schema_hash: document.schema_hash,
            sections: document.sections,
            rows,
            by_key,
            by_path,
        })
    }

    /// The row with dotted key `key`.
    pub fn row(&self, key: &str) -> Option<&Row> {
        self.by_key.get(key).map(|index| &self.rows[*index])
    }

    /// The row at key path `path`.
    pub fn row_at(&self, path: &[String]) -> Option<&Row> {
        self.by_path.get(path).map(|index| &self.rows[*index])
    }

    /// Rows of one section, in schema order (every row for `None`).
    pub fn rows_in<'a>(&'a self, section: Option<&'a str>) -> impl Iterator<Item = &'a Row> + 'a {
        self.rows.iter().filter(move |row| section.is_none_or(|id| row.section == id))
    }
}

fn row(raw: Value) -> Result<Row, String> {
    let parsed: RawRow = serde_json::from_value(raw.clone()).map_err(|error| error.to_string())?;
    let range = || parsed.range.clone().ok_or_else(|| format!("{}: range missing", parsed.key));
    let kind = match parsed.kind.as_str() {
        "toggle" => Kind::Toggle,
        "choice" => Kind::Choice(parsed.choices.clone()),
        "choice_or_number" => Kind::ChoiceOrNumber(parsed.choices.clone(), range()?),
        "number" => Kind::Number(range()?),
        "color" => Kind::Color,
        "sound" => Kind::Sound,
        "url" => Kind::Url,
        "host_list" => Kind::HostList,
        "time_range" => Kind::TimeRange,
        "theme" => Kind::Theme,
        "font_family" => Kind::FontFamily,
        other => return Err(format!("{}: unknown kind {other}", parsed.key)),
    };
    let validation = match parsed.validation.as_str() {
        "portable" => Validation::Portable,
        "domain:theme" => Validation::Domain(DomainKind::Theme),
        "domain:font_family" => Validation::Domain(DomainKind::FontFamily),
        "domain:sound" => Validation::Domain(DomainKind::Sound),
        other => return Err(format!("{}: unknown validation {other}", parsed.key)),
    };
    Ok(Row {
        key: parsed.key,
        path: parsed.path,
        section: parsed.section,
        group: parsed.group,
        title: parsed.title,
        help: parsed.help,
        kind,
        default: parsed.default.map(canonical),
        default_label: parsed.default_label,
        keywords: parsed.keywords,
        agent_settable: parsed.agent_settable,
        agent_refusal: parsed.agent_refusal,
        kept_on_reset_all: parsed.kept_on_reset_all,
        validation,
        accepts: parsed.accepts.into_iter().map(canonical).collect(),
        refuses: parsed.refuses.into_iter().map(canonical).collect(),
        raw,
    })
}
