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
    /// A document of a schema (`cmux.particles/1`) and why this one is not
    /// one: the validator's first bad path and what is wrong there.
    Document {
        schema: &'static str,
        reason: String,
    },
    /// A name from a value domain; `values` is `None` while the app has not
    /// published the domain.
    Domain {
        name: &'static str,
        values: Option<Vec<String>>,
    },
    /// A `json` row: a value matching the row's JSON Schema, and what was
    /// wrong with this one (`{at, why, token?}` per problem, the shape's first
    /// mismatch or the sidebar row reducer's problems).
    Json {
        /// Boxed: a Refusal stays small enough to return by value.
        schema: Box<Value>,
        problems: Vec<Value>,
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
            Accepted::Document { schema, reason } => json!({"schema": schema, "reason": reason}),
            Accepted::Domain { name, values } => json!({"domain": name, "values": values}),
            Accepted::Json { schema, problems } => {
                json!({"shape": "JSON matching the schema", "schema": schema, "problems": problems})
            }
        }
    }

    /// The first problem in words (`sidebar.workspaceRow.lines[3]: tooManyLines`), for the
    /// refusal's message.
    pub fn first_problem(&self) -> Option<String> {
        let Accepted::Json { problems, .. } = self else { return None };
        let problem = problems.first()?;
        let at = problem.get("at").and_then(Value::as_str).unwrap_or_default();
        let why = problem.get("why").and_then(Value::as_str).unwrap_or_default();
        Some(match problem.get("token").and_then(Value::as_str) {
            Some(token) => format!("{at}: {why} ({token})"),
            None if at.is_empty() => why.to_owned(),
            None => format!("{at}: {why}"),
        })
    }
}

/// The problems of `value` for a `json` row: the shape's first mismatch, then
/// the row's domain's own (the sidebar row reducer's). Empty: accepted.
fn json_problems(row: &Row, shape: &Value, value: &Value) -> Vec<Value> {
    if let Err(why) = super::shape::matches(shape, value) {
        let (at, why) = match why.split_once(": ") {
            Some((path, why)) => (format!("{}{path}", row.key), why.to_owned()),
            None => (row.key.clone(), why),
        };
        return vec![json!({"at": at, "why": why})];
    }
    match row.validation {
        super::Validation::Domain(domain) if super::sidebar_rows::is_sidebar_rows(domain) => {
            super::sidebar_row_problems(domain, value)
        }
        _ => Vec::new(),
    }
}

/// `Ok` when the app would apply `value` for `row` without a diagnostic.
/// Numbers outside the range are refused although the parser clamps them.
pub fn accepts(row: &Row, value: &Value, domains: &Domains) -> Result<(), Refusal> {
    if row.validation == super::Validation::Domain(DomainKind::ParticlesDocument) {
        return particles_document(value).map_err(|reason| Refusal::InvalidValue {
            key: row.key.clone(),
            kind: row.kind.name(),
            accepted: Accepted::Document { schema: cmux_app_host::particles::SCHEMA, reason },
            value: value.clone(),
        });
    }
    if let Kind::Json(shape) = &row.kind {
        let problems = json_problems(row, shape, value);
        if problems.is_empty() {
            return Ok(());
        }
        return Err(Refusal::InvalidValue {
            key: row.key.clone(),
            kind: row.kind.name(),
            accepted: Accepted::Json { schema: Box::new(shape.clone()), problems },
            value: value.clone(),
        });
    }
    if row_accepts(row, value, domains) {
        return Ok(());
    }
    let accepted = if is_backdrop_selection(row) {
        Accepted::Shape(
            "none, a listed painting, system:<absolute path>, file:<absolute path>, youtube:<video id> (or a YouTube video address) or folder:<absolute path>",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::BackdropPicture) {
        Accepted::Shape(
            "a listed painting, desktop, system:<absolute path>, file:<absolute path> or youtube:<video id> (or a YouTube video address)",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::BackdropPictures) {
        Accepted::Shape(
            "a list of pictures: listed paintings, desktop, system:<absolute path> or file:<absolute path>",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::BackdropSchedule) {
        Accepted::Shape(
            "an object of HH:MM or dawn, sunrise, noon, sunset, dusk (with +Nm, -Nm, +Nh or -Nh) to fixed backgrounds",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::BackdropLocation) {
        Accepted::Shape("\"LAT,LON\" in degrees, such as \"37.77,-122.42\"")
    } else if row.validation == super::Validation::Domain(DomainKind::BackdropMemory) {
        Accepted::Shape(
            "an object of rotate (daily or folder:<absolute path>), folder (folder:<absolute path>) and off (none or a fixed background)",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::BackdropPlacement) {
        Accepted::Shape(
            "an object of picture ids to fill, fit, center or stretch, then optionally X Y (0 to 1) and a zoom (1 to 4), such as \"fill 0.3 0.7 1.5\"",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::BackdropRecents) {
        Accepted::Shape(
            "an array of at most 8 different backgrounds (none, daily, a listed painting, desktop, system:, file: or folder:<absolute path>, youtube:<video id>), newest first",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::ChatRoots) {
        Accepted::Shape(
            "an array of absolute folders outside / , the home folder, other volumes and privacy-protected folders",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::SearchTemplate) {
        Accepted::Shape("an address with %s or {searchTerms}, or \"\"")
    } else if row.validation == super::Validation::Domain(DomainKind::CustomDensities) {
        Accepted::Shape("an array of density objects, each with a lowercase id and a name")
    } else if row.validation == super::Validation::Domain(DomainKind::CommandLabels) {
        Accepted::Shape(
            "an array of preset names and rule objects, each with a label and a program or match",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::TranscriptTokens) {
        Accepted::Shape(
            "an object of transcript look tokens, each in its range (docs/cmux-next/transcript-customization.md)",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::Hosts) {
        Accepted::Shape(
            "an array of hosts, each with a unique label and endpoints (ssh addresses tried in order)",
        )
    } else if row.validation == super::Validation::Domain(DomainKind::AppId) {
        Accepted::Shape("an app id, publisher/name in lowercase letters, digits and -")
    } else if row.validation == super::Validation::Domain(DomainKind::SidebarSectionIds) {
        Accepted::Shape("an array of at most 256 distinct section ids of 1 to 128 characters")
    } else if row.validation == super::Validation::Domain(DomainKind::UiFontFamily) {
        Accepted::Domain { name: domain_name(DomainKind::UiFontFamily), values: None }
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
/// An unset row that replaced retired keys reads the first of them whose value
/// the retired-keys table lists (`super::retired`), as the app does, and an old
/// choice value reads as its replacement (`super::aliases`).
pub fn effective_value(row: &Row, root: &Value, domains: &Domains) -> Option<Value> {
    let stored =
        crate::value::value_at(root, &row.path).or_else(|| super::replaced_value(&row.path, root));
    let stored = stored.map(|stored| aliased(row, stored));
    match stored {
        Some(stored) if row_accepts(row, &stored, domains) => Some(stored),
        _ => row.default.clone(),
    }
}

/// `value` as the row reads it: an old choice value as its replacement.
pub fn aliased(row: &Row, value: &Value) -> Value {
    value
        .as_str()
        .and_then(|old| super::choice_alias(&row.key, old))
        .map_or_else(|| value.clone(), |new| Value::String(new.to_owned()))
}

fn is_backdrop_selection(row: &Row) -> bool {
    row.validation == super::Validation::Domain(DomainKind::BackdropSelection)
}

/// Values written by older cmux-next builds for the hand-written Swift
/// `WorkspaceColorIndicatorStyle` enum. Swift reads each as its canonical
/// replacement without a diagnostic, so the shared Rust validator must do the
/// same or customization would reject an otherwise valid user config.
fn accepts_legacy_workspace_color_indicator(row: &Row, value: &Value) -> bool {
    row.key == "workspaceColors.indicatorStyle"
        && value.as_str().is_some_and(|text| {
            matches!(
                text,
                "solidFill"
                    | "rail"
                    | "border"
                    | "wash"
                    | "lift"
                    | "typography"
                    | "washRail"
                    | "blueWashColorRail"
            )
        })
}

fn row_accepts(row: &Row, value: &Value, domains: &Domains) -> bool {
    if let Kind::Json(shape) = &row.kind {
        return json_problems(row, shape, value).is_empty();
    }
    if accepts_legacy_workspace_color_indicator(row, value) {
        return true;
    }
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
        super::Validation::Domain(DomainKind::UiFontFamily) => {
            return value.as_str().is_some_and(|text| font_ok(text, None));
        }
        super::Validation::Domain(DomainKind::BackdropPicture) => {
            return value.as_str().is_some_and(super::backdrop::is_picture);
        }
        super::Validation::Domain(DomainKind::BackdropPictures) => {
            return value.as_array().is_some_and(|items| {
                items.iter().all(|item| item.as_str().is_some_and(super::backdrop::is_picture))
            });
        }
        super::Validation::Domain(DomainKind::BackdropSchedule) => {
            return super::backdrop::is_schedule(value);
        }
        super::Validation::Domain(DomainKind::BackdropLocation) => {
            return value.as_str().is_some_and(super::backdrop::is_location);
        }
        super::Validation::Domain(DomainKind::BackdropMemory) => {
            return super::backdrop::is_memory(value);
        }
        super::Validation::Domain(DomainKind::BackdropPlacement) => {
            return crate::backdrop_placement::is_placement_map(value);
        }
        super::Validation::Domain(DomainKind::BackdropRecents) => {
            return super::backdrop::is_recents(value);
        }
        super::Validation::Domain(DomainKind::CustomDensities) => {
            return value.as_array().is_some_and(|items| items.iter().all(is_custom_density));
        }
        super::Validation::Domain(DomainKind::CommandLabels) => {
            return value.as_array().is_some_and(|items| items.iter().all(is_command_label));
        }
        super::Validation::Domain(DomainKind::AppId) => {
            return value.as_str().is_some_and(super::app_id::is_valid_app_id);
        }
        super::Validation::Domain(DomainKind::ParticlesDocument) => {
            return particles_document(value).is_ok();
        }
        super::Validation::Domain(DomainKind::TranscriptTokens) => {
            return crate::transcript_look::accepts_tokens(value);
        }
        super::Validation::Domain(DomainKind::SidebarSectionIds) => {
            return is_sidebar_section_ids(value);
        }
        super::Validation::Domain(DomainKind::Hosts) => {
            return crate::hosts::accepts(value);
        }
        _ => {}
    }
    if is_backdrop_selection(row) {
        let Some(text) = value.as_str() else { return false };
        // `system:<absolute path>` (a macOS wallpaper), `file:<absolute
        // path>` (the person's own image or video), a canonical `youtube:`
        // video or `folder:<absolute path>` (the pictures of a folder
        // shuffled, never `/` alone), as Swift `BackdropSelectionSetting`.
        let path = super::backdrop::is_path_or_video(text);
        let folder = text
            .strip_prefix("folder:")
            .is_some_and(|path| path.starts_with('/') && path.len() > 1);
        let live = super::backdrop::is_live(text);
        return path || folder || live || is_accepted(&row.kind, value, domains);
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
        Kind::Json(shape) => super::shape::matches(shape, value).is_ok(),
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

/// Swift `CommandLabelsSetting.isItem`: a non-blank preset name, or an object
/// with a non-blank `label`, a non-blank `program` (or a non-empty list of
/// them) or `match`, and string `link` and `icon` when present.
fn is_command_label(value: &Value) -> bool {
    let non_blank = |value: &Value| value.as_str().is_some_and(|text| !text.trim().is_empty());
    if value.is_string() {
        return non_blank(value);
    }
    let Some(members) = value.as_object() else { return false };
    if !members.get("label").is_some_and(non_blank) {
        return false;
    }
    let program_ok = members.get("program").is_none_or(|program| match program.as_array() {
        Some(names) => !names.is_empty() && names.iter().all(non_blank),
        None => non_blank(program),
    });
    let match_ok = members.get("match").is_none_or(non_blank);
    let strings_ok =
        ["link", "icon"].iter().all(|key| members.get(*key).is_none_or(Value::is_string));
    program_ok
        && match_ok
        && strings_ok
        && (members.contains_key("program") || members.contains_key("match"))
}

/// A `cmux.particles/1` document the one validator (cmux-app-host
/// `particles::validate`, which also checks every scene's `choreography`)
/// accepts, else its reason (`phases.row.frames[3].dots[1][2]: must be from 0
/// to 4`). The settings file holds the document itself; a look that keeps it
/// in a file of its folder has it inlined when the look is read
/// (cmux-customize `setup::inline_documents`).
fn particles_document(value: &Value) -> Result<(), String> {
    cmux_app_host::particles::validate(value).map_err(|error| error.to_string())
}

/// The most ids a sidebar section list holds, and the longest id
/// (cmux-layout-reducer `sidebar_section_customization`).
pub const MAX_SECTION_IDS: usize = 256;
pub const MAX_SECTION_ID_CHARS: usize = 128;

/// Swift `SidebarSectionIDsSetting.accepts`: at most 256 distinct ids of 1
/// to 128 characters, the lists the sidebar planner reads with no problem.
fn is_sidebar_section_ids(value: &Value) -> bool {
    let Some(items) = value.as_array() else { return false };
    let mut seen = BTreeSet::new();
    items.len() <= MAX_SECTION_IDS
        && items.iter().all(|item| {
            item.as_str().is_some_and(|id| {
                !id.is_empty() && id.chars().count() <= MAX_SECTION_ID_CHARS && seen.insert(id)
            })
        })
}

/// Swift `BrowserOmnibarSetting.isSearchTemplate`: empty, or an address
/// with a `%s` or `{searchTerms}` placeholder that is valid once filled.
pub fn is_search_template(text: &str) -> bool {
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
        Kind::Json(shape) => {
            Accepted::Json { schema: Box::new(shape.clone()), problems: Vec::new() }
        }
    }
}

fn domain_name(kind: DomainKind) -> &'static str {
    match kind {
        DomainKind::Theme => "theme",
        DomainKind::FontFamily => "font_family",
        DomainKind::UiFontFamily => "ui_font_family",
        DomainKind::Sound => "sound",
        DomainKind::BackdropSelection => "backdrop_selection",
        DomainKind::BackdropPicture => "backdrop_picture",
        DomainKind::BackdropPictures => "backdrop_pictures",
        DomainKind::BackdropSchedule => "backdrop_schedule",
        DomainKind::BackdropLocation => "backdrop_location",
        DomainKind::BackdropMemory => "backdrop_memory",
        DomainKind::BackdropPlacement => "backdrop_placement",
        DomainKind::BackdropRecents => "backdrop_recents",
        DomainKind::ChatRoots => "chat_roots",
        DomainKind::SearchTemplate => "search_template",
        DomainKind::CustomDensities => "custom_densities",
        DomainKind::CommandLabels => "command_labels",
        DomainKind::AppId => "app_id",
        DomainKind::ParticlesDocument => "particles_document",
        DomainKind::SidebarRowLines => "sidebar_row_lines",
        DomainKind::SidebarRowLinesByKind => "sidebar_row_lines_by_kind",
        DomainKind::SidebarRowLinesByAgent => "sidebar_row_lines_by_agent",
        DomainKind::TranscriptTokens => "transcript_tokens",
        DomainKind::SidebarSectionIds => "sidebar_section_ids",
        DomainKind::Hosts => "hosts",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_color_indicator_accepts_swift_legacy_values() {
        let row = super::super::Schema::embedded()
            .row("workspaceColors.indicatorStyle")
            .expect("workspace color indicator row");
        for value in [
            "solidFill",
            "rail",
            "border",
            "wash",
            "lift",
            "typography",
            "washRail",
            "blueWashColorRail",
        ] {
            assert!(
                accepts(row, &Value::String(value.to_owned()), &Default::default()).is_ok(),
                "{value}"
            );
        }
        assert!(
            accepts(row, &Value::String("__not_a_choice__".to_owned()), &Default::default())
                .is_err()
        );
    }

    #[test]
    fn profile_menu_style_takes_app_or_account_and_defaults_to_app() {
        // ask-aad661801e: the Claude Code and Codex looks set the account-first profile menu;
        // cmux's own app menu stays the default.
        let row = super::super::Schema::embedded()
            .row("sidebar.profileMenu.style")
            .expect("profile menu style row");
        assert_eq!(row.default, Some(json!("app")));
        let domains = Domains::default();
        for value in ["app", "account"] {
            assert!(accepts(row, &json!(value), &domains).is_ok(), "{value}");
        }
        for value in [json!("accounts"), json!(""), json!(true), json!(1)] {
            assert!(accepts(row, &value, &domains).is_err(), "{value}");
        }
    }

    #[test]
    fn app_font_takes_any_family_not_only_the_fixed_pitch_domain() {
        let row = super::super::Schema::embedded().row("appearance.appFont").expect("app font row");
        assert_eq!(row.validation, super::super::Validation::Domain(DomainKind::UiFontFamily));
        let mono = Domains::published(Vec::new(), vec!["Menlo".to_owned()], Vec::new());
        assert!(accepts(row, &json!("Avenir Next"), &mono).is_ok());
        assert!(accepts(row, &json!("Bad#Name"), &mono).is_err());
        assert!(accepts(row, &json!(3), &mono).is_err());
    }
}
