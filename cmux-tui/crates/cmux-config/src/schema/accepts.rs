//! Write validation per kind (Swift `SettingDescriptor.accepts`).

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::{Choice, DomainKind, Kind, NumberRange, Row, new_tab_page_url_is_valid};
use crate::domains::Domains;
use crate::refusal::Refusal;
use crate::text::{
    ThemeSpec, is_hex_digit, is_valid_font_family, quiet_hours_minutes, trim_whitespaces,
};

/// What a row accepts, for refusals and clients.
#[derive(Debug, Clone, PartialEq)]
pub enum Accepted {
    Choices(Vec<String>),
    Range {
        min: f64,
        max: f64,
    },
    ChoicesOrRange {
        choices: Vec<String>,
        min: f64,
        max: f64,
    },
    /// A fixed shape, described in words (`boolean`, `#RRGGBB or #RRGGBBAA`, ...).
    Shape(&'static str),
    /// A name from a value domain; `values` is `None` while the app has not
    /// published the domain.
    Domain {
        name: &'static str,
        values: Option<Vec<String>>,
    },
}

impl Accepted {
    pub fn to_json(&self) -> Value {
        match self {
            Accepted::Choices(choices) => json!({"choices": choices}),
            Accepted::Range { min, max } => json!({"range": {"min": min, "max": max}}),
            Accepted::ChoicesOrRange { choices, min, max } => {
                json!({"choices": choices, "range": {"min": min, "max": max}})
            }
            Accepted::Shape(shape) => json!({"shape": shape}),
            Accepted::Domain { name, values } => json!({"domain": name, "values": values}),
        }
    }
}

/// `Ok` when the app would apply `value` for `row` without a diagnostic.
/// Numbers outside the range are refused although the parser clamps them.
pub fn accepts(row: &Row, value: &Value, domains: &Domains) -> Result<(), Refusal> {
    if row_accepts(row, value, domains) {
        return Ok(());
    }
    let accepted = if is_backdrop_selection(row) {
        Accepted::Shape("none, a listed painting, or system:<absolute path>")
    } else {
        accepted(&row.kind, domains)
    };
    Err(Refusal::InvalidValue {
        key: row.key.clone(),
        kind: row.kind.name(),
        accepted,
        value: value.clone(),
    })
}

/// The stored value when valid, else the default (what the app applies).
pub fn effective_value(row: &Row, root: &Value, domains: &Domains) -> Option<Value> {
    match crate::value::value_at(root, &row.path) {
        Some(stored) if row_accepts(row, stored, domains) => Some(stored.clone()),
        _ => row.default.clone(),
    }
}

fn is_backdrop_selection(row: &Row) -> bool {
    row.validation == super::Validation::Domain(DomainKind::BackdropSelection)
}

fn row_accepts(row: &Row, value: &Value, domains: &Domains) -> bool {
    if is_backdrop_selection(row) {
        let Some(text) = value.as_str() else { return false };
        let system_path = text.strip_prefix("system:").is_some_and(|path| path.starts_with('/'));
        return system_path || is_accepted(&row.kind, value, domains);
    }
    is_accepted(&row.kind, value, domains)
}

fn is_accepted(kind: &Kind, value: &Value, domains: &Domains) -> bool {
    match kind {
        Kind::Choice(choices) => value.as_str().is_some_and(|text| has_choice(choices, text)),
        Kind::ChoiceOrNumber(choices, range) => match value {
            Value::String(text) => has_choice(choices, text),
            Value::Number(number) => number.as_f64().is_some_and(|x| in_range(range, x)),
            _ => false,
        },
        Kind::Toggle => value.is_boolean(),
        Kind::Number(range) => value.as_f64().is_some_and(|x| x.is_finite() && in_range(range, x)),
        Kind::Color => value.as_str().is_some_and(is_hex_color),
        Kind::Url => {
            value.as_str().is_some_and(|text| text.is_empty() || new_tab_page_url_is_valid(text))
        }
        Kind::HostList => value.as_array().is_some_and(|items| items.iter().all(Value::is_string)),
        Kind::TimeRange => value.as_object().is_some_and(|members| {
            let minutes = |name: &str| {
                members.get(name).and_then(Value::as_str).and_then(quiet_hours_minutes)
            };
            minutes("start").is_some() && minutes("end").is_some()
        }),
        Kind::Theme => value.as_str().is_some_and(|text| theme_ok(text, domains.themes.as_ref())),
        Kind::FontFamily => {
            value.as_str().is_some_and(|text| font_ok(text, domains.font_families.as_ref()))
        }
        Kind::Sound => value.as_str().is_some_and(|text| sound_ok(text, domains.sounds.as_ref())),
    }
}

fn has_choice(choices: &[Choice], text: &str) -> bool {
    choices.iter().any(|choice| choice.value == text)
}

fn in_range(range: &NumberRange, x: f64) -> bool {
    range.min <= x && x <= range.max
}

/// `#RRGGBB` or `#RRGGBBAA`; the `#` is optional (Swift `isHexColor`).
pub fn is_hex_color(text: &str) -> bool {
    let digits = text.strip_prefix('#').unwrap_or(text);
    let count = digits.chars().count();
    (count == 6 || count == 8) && digits.chars().all(is_hex_digit)
}

/// A theme spec Ghostty can take; with a published domain, every theme it
/// names is in the domain.
fn theme_ok(text: &str, domain: Option<&BTreeSet<String>>) -> bool {
    let Some(spec) = ThemeSpec::parse(text) else {
        return false;
    };
    domain.is_none_or(|names| names.contains(&spec.light) && names.contains(&spec.dark))
}

fn font_ok(text: &str, domain: Option<&BTreeSet<String>>) -> bool {
    is_valid_font_family(text) && domain.is_none_or(|names| names.contains(trim_whitespaces(text)))
}

/// `default` and `none` are always sounds; with a published domain anything
/// else must be in it. With none published any string is a sound (Swift
/// `SettingDescriptor.accepts` checks only the type).
fn sound_ok(text: &str, domain: Option<&BTreeSet<String>>) -> bool {
    text == "default" || text == "none" || domain.is_none_or(|names| names.contains(text))
}

fn accepted(kind: &Kind, domains: &Domains) -> Accepted {
    fn values(choices: &[Choice]) -> Vec<String> {
        choices.iter().map(|choice| choice.value.clone()).collect()
    }
    fn domain(name: &'static str, set: Option<&BTreeSet<String>>) -> Accepted {
        Accepted::Domain { name, values: set.map(|names| names.iter().cloned().collect()) }
    }
    match kind {
        Kind::Choice(choices) => Accepted::Choices(values(choices)),
        Kind::ChoiceOrNumber(choices, range) => {
            Accepted::ChoicesOrRange { choices: values(choices), min: range.min, max: range.max }
        }
        Kind::Number(range) => Accepted::Range { min: range.min, max: range.max },
        Kind::Toggle => Accepted::Shape("boolean"),
        Kind::Color => Accepted::Shape("#RRGGBB or #RRGGBBAA"),
        Kind::Url => Accepted::Shape("an http, https, file or about address, or \"\""),
        Kind::HostList => Accepted::Shape("an array of host names"),
        Kind::TimeRange => Accepted::Shape("{\"start\": \"HH:MM\", \"end\": \"HH:MM\"}"),
        Kind::Theme => domain(domain_name(DomainKind::Theme), domains.themes.as_ref()),
        Kind::FontFamily => {
            domain(domain_name(DomainKind::FontFamily), domains.font_families.as_ref())
        }
        Kind::Sound => domain(domain_name(DomainKind::Sound), domains.sounds.as_ref()),
    }
}

fn domain_name(kind: DomainKind) -> &'static str {
    match kind {
        DomainKind::Theme => "theme",
        DomainKind::FontFamily => "font_family",
        DomainKind::Sound => "sound",
        DomainKind::BackdropSelection => "backdrop_selection",
    }
}
