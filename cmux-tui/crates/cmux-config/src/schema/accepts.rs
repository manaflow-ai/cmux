//! Write validation per kind (Swift `SettingDescriptor.accepts`).

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::{
    Choice, DomainKind, Kind, NumberRange, Row, is_http_origin, new_tab_page_url_is_valid,
};
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
    /// One of the choices, or an object of the shape described in words.
    ChoicesOrShape {
        choices: Vec<String>,
        shape: String,
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
            Accepted::ChoicesOrShape { choices, shape } => {
                json!({"choices": choices, "shape": shape})
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
        Accepted::Shape(
            "none, a listed painting, system:<absolute path>, file:<absolute path> or folder:<absolute path>",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::ChatRoots) {
        Accepted::Shape(
            "an array of absolute folders outside / , the home folder, other volumes and privacy-protected folders",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::SearchTemplate) {
        Accepted::Shape("an address with %s or {searchTerms}, or \"\"")
    } else if row.validation == super::Validation::Domain(DomainKind::CustomDensities) {
        Accepted::Shape("an array of density objects, each with a lowercase id and a name")
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
    match row.validation {
        super::Validation::Domain(DomainKind::ChatRoots) => {
            let home = std::env::var("HOME").unwrap_or_default();
            return value.as_array().is_some_and(|items| {
                items.iter().all(|item| {
                    item.as_str().is_some_and(|path| super::chat_root_is_valid(path, &home))
                })
            });
        }
        super::Validation::Domain(DomainKind::SearchTemplate) => {
            return value.as_str().is_some_and(is_search_template);
        }
        super::Validation::Domain(DomainKind::CustomDensities) => {
            return value.as_array().is_some_and(|items| items.iter().all(is_custom_density));
        }
        _ => {}
    }
    if is_backdrop_selection(row) {
        let Some(text) = value.as_str() else { return false };
        // `system:<absolute path>` (a macOS wallpaper), `file:<absolute
        // path>` (the person's own image) or `folder:<absolute path>` (the
        // pictures of a folder shuffled, never `/` alone), as Swift
        // `BackdropSelectionSetting`.
        let path = ["system:", "file:"]
            .iter()
            .any(|prefix| text.strip_prefix(prefix).is_some_and(|path| path.starts_with('/')));
        let folder = text
            .strip_prefix("folder:")
            .is_some_and(|path| path.starts_with('/') && path.len() > 1);
        return path || folder || is_accepted(&row.kind, value, domains);
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
        Kind::ChoiceOrUrl(choices, url_key) => match value {
            Value::String(text) => has_choice(choices, text),
            Value::Object(members) => {
                members.len() == 1
                    && members.get(url_key).and_then(Value::as_str).is_some_and(is_http_origin)
            }
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
        Kind::Text => value.is_string(),
        Kind::FolderList => value.as_array().is_some_and(|items| {
            items.iter().all(|item| {
                item.as_str().is_some_and(|path| path.starts_with('/') || path.starts_with("~/"))
            })
        }),
        Kind::StringList => value.as_array().is_some_and(|items| {
            items.iter().all(|item| item.as_str().is_some_and(|text| !text.is_empty()))
        }),
        Kind::OrderedChoices(choices) => value.as_array().is_some_and(|items| {
            items.iter().all(|item| item.as_str().is_some_and(|text| has_choice(choices, text)))
        }),
        Kind::NumberList(range) => value.as_array().is_some_and(|items| {
            items
                .iter()
                .all(|item| item.as_f64().is_some_and(|x| x.is_finite() && in_range(range, x)))
        }),
        Kind::StringMap => {
            value.as_object().is_some_and(|members| members.values().all(Value::is_string))
        }
        Kind::SoundRules => {
            value.as_object().is_some_and(|members| members.values().all(is_sound_rule))
        }
    }
}

/// The events a sound rule may name (Swift `NotificationSoundEvent`).
pub(crate) const SOUND_RULE_EVENTS: [&str; 5] =
    ["finished", "needsInput", "error", "bell", "message"];

/// Swift `NotificationSoundRule.accepts`: a sound name, or an object of an
/// optional string `sound`, an optional `volume` from 0 to 1, and optional
/// `events` naming known events with string sounds; nothing else.
fn is_sound_rule(value: &Value) -> bool {
    if value.is_string() {
        return true;
    }
    let Some(members) = value.as_object() else { return false };
    members.iter().all(|(key, member)| match key.as_str() {
        "sound" => member.is_string(),
        "volume" => member.as_f64().is_some_and(|x| x.is_finite() && (0.0..=1.0).contains(&x)),
        "events" => member.as_object().is_some_and(|events| {
            events.iter().all(|(name, sound)| {
                SOUND_RULE_EVENTS.contains(&name.as_str()) && sound.is_string()
            })
        }),
        _ => false,
    })
}

/// Swift `CustomDensitiesSetting.density(from:)`: an object with a density
/// id (1 to 64 lowercase ASCII letters, digits and hyphens, not starting with
/// a hyphen), a non-blank name, optional finite `level`, `spacing` and
/// `fontSize` numbers, and optional `tokens` of non-negative finite numbers.
fn is_custom_density(value: &Value) -> bool {
    let Some(members) = value.as_object() else { return false };
    let id_ok = members.get("id").and_then(Value::as_str).is_some_and(|id| {
        (1..=64).contains(&id.chars().count())
            && !id.starts_with('-')
            && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    });
    let name_ok =
        members.get("name").and_then(Value::as_str).is_some_and(|name| !name.trim().is_empty());
    let numbers_ok = ["level", "spacing", "fontSize"]
        .iter()
        .all(|key| members.get(*key).is_none_or(|v| v.as_f64().is_some_and(f64::is_finite)));
    let tokens_ok = members.get("tokens").is_none_or(|tokens| {
        tokens.as_object().is_some_and(|entries| {
            entries.values().all(|v| v.as_f64().is_some_and(|x| x.is_finite() && x >= 0.0))
        })
    });
    id_ok && name_ok && numbers_ok && tokens_ok
}

/// Swift `BrowserOmnibarSetting.isSearchTemplate`: empty, or an address
/// with a `%s` or `{searchTerms}` placeholder that is valid once filled.
fn is_search_template(text: &str) -> bool {
    let trimmed = trim_whitespaces(text);
    if trimmed.is_empty() {
        return true;
    }
    if !trimmed.contains("%s") && !trimmed.contains("{searchTerms}") {
        return false;
    }
    new_tab_page_url_is_valid(&trimmed.replace("%s", "x").replace("{searchTerms}", "x"))
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
    // `appearance.appTheme` follows the terminal theme by default.
    if text == "followTerminal" {
        return true;
    }
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
        Kind::ChoiceOrUrl(choices, url_key) => Accepted::ChoicesOrShape {
            choices: values(choices),
            shape: format!("{{\"{url_key}\": \"http(s)://host[:port]\"}}"),
        },
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
        Kind::Text => Accepted::Shape("a string"),
        Kind::FolderList => Accepted::Shape("an array of /absolute or ~/ folder paths"),
        Kind::StringList => Accepted::Shape("an array of non-empty strings"),
        Kind::OrderedChoices(choices) => Accepted::Choices(values(choices)),
        Kind::NumberList(range) => Accepted::Range { min: range.min, max: range.max },
        Kind::StringMap => Accepted::Shape("an object of strings"),
        Kind::SoundRules => Accepted::Shape(
            "an object of sound names or {\"sound\": name, \"volume\": 0...1, \"events\": {event: name}}",
        ),
    }
}

fn domain_name(kind: DomainKind) -> &'static str {
    match kind {
        DomainKind::Theme => "theme",
        DomainKind::FontFamily => "font_family",
        DomainKind::Sound => "sound",
        DomainKind::BackdropSelection => "backdrop_selection",
        DomainKind::ChatRoots => "chat_roots",
        DomainKind::SearchTemplate => "search_template",
        DomainKind::CustomDensities => "custom_densities",
    }
}
