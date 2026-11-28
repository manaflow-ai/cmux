//! The settings schema export (`schemas/settings/settings-schema.json`), written here, not in
//! Swift (Swift `SettingsSchemaExport`, `SettingSurfacePlan`, `SettingsSchemaSamples` and
//! `DeterministicJSON`). The app sends the descriptor registry's own facts; everything the export
//! derives from them is computed here: each row's surfaces, validation, kept-on-reset flag, app id
//! pattern and conformance samples, the catalog check and the file's text.
//!
//! - `schema.json_text` `{value, pretty?}` answers `{text}`: `value` as JSON whose text does not
//!   depend on a toolchain ([`json_text`]).
//! - `schema.surfaces` `{key, kind, consumers, agent_settable, palette_hidden?}` answers
//!   `{surfaces}`: the row's palette, CLI, MCP and socket bindings ([`surfaces`]).
//!   `palette_hidden` is the reason a row is hidden from the palette, null when it is exposed.
//! - `schema.export` `{sections, page, rows, catalog}` answers `{text}`, the whole file with its
//!   trailing newline, or `{missing}`: the catalog keys the texts name that `catalog` (the string
//!   catalog's keys) lacks, sorted. Each row is the descriptor's export row without `surfaces`,
//!   `validation`, `pattern`, `kept_on_reset_all`, `accepts` and `refuses`, with
//!   `palette_hidden` ([`export_row`]).

use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::sync::OnceLock;

use serde_json::{Map, Number, Value, json};

use super::accepts;
use crate::app_ops::OpError;
use crate::schema::Row;
use crate::value::number_value;

/// The per-row facts that are not a row's own definition (validation domains, kept on Reset All,
/// the app id rule).
static ROW_FACTS: &str = include_str!("../../../../../schemas/settings/source/row-facts.json");
/// The conformance sample sets, by validation domain and by kind.
static SAMPLES: &str = include_str!("../../../../../schemas/settings/source/samples.json");

/// Format version of the export; bump on an incompatible change.
pub const EXPORT_VERSION: u64 = 1;
/// The consumer that draws the native Settings page and palette.
const CMUX_NEXT: &str = "cmux-next";
/// Swift `SettingSurfacePlan.cliOperations`.
const CLI_OPERATIONS: [&str; 4] =
    ["settings.list", "settings.get", "settings.set", "settings.reset"];
/// Swift `SettingSurfacePlan.resetAliases`.
const RESET_ALIASES: [&str; 1] = ["settings.unset"];
const MCP_READ: [&str; 2] = ["settings.list", "settings.get"];
const MCP_WRITE: [&str; 2] = ["settings.set", "settings.reset"];
const APP_OPERATIONS: [&str; 3] = ["settings.get", "settings.set", "settings.reset"];
/// The export members whose values are settings values, not texts.
const VALUE_MEMBERS: [&str; 4] = ["default", "accepts", "refuses", "shape"];

pub(super) fn json_text_op(request: &Value) -> Result<Value, OpError> {
    let value =
        request.get("value").ok_or_else(|| OpError::Invalid("expected a `value`".to_owned()))?;
    let pretty = request.get("pretty").and_then(Value::as_bool).unwrap_or(false);
    Ok(json!({ "text": json_text(value, pretty)? }))
}

pub(super) fn surfaces_op(request: &Value) -> Result<Value, OpError> {
    Ok(json!({ "surfaces": surfaces(&SurfaceFacts::of(request)?) }))
}

pub(super) fn export_op(request: &Value) -> Result<Value, OpError> {
    let member = |name: &str| {
        request.get(name).cloned().ok_or_else(|| OpError::Invalid(format!("expected `{name}`")))
    };
    let rows = match request.get("rows") {
        Some(Value::Array(rows)) => rows,
        _ => return Err(OpError::Invalid("expected an array `rows`".to_owned())),
    };
    let catalog: BTreeSet<&str> = match request.get("catalog") {
        Some(Value::Array(keys)) => keys.iter().filter_map(Value::as_str).collect(),
        _ => return Err(OpError::Invalid("expected an array `catalog`".to_owned())),
    };
    let rows = rows
        .iter()
        .map(|row| match row {
            Value::Object(row) => export_row(row.clone()),
            _ => Err(OpError::Invalid("expected each row as an object".to_owned())),
        })
        .collect::<Result<Vec<_>, _>>()?;
    let document = json!({
        "version": EXPORT_VERSION,
        "sections": member("sections")?,
        "page": member("page")?,
        "rows": rows,
    });
    let missing = missing_keys(&document, &catalog);
    if !missing.is_empty() {
        return Ok(json!({ "missing": missing }));
    }
    Ok(json!({ "text": json_text(&document, true)? + "\n" }))
}

// MARK: - The writer

/// Swift `DeterministicJSON.string(_:pretty:)`: `value` as JSON text that is the same on every
/// toolchain. Keys sort case-insensitively, ties by exact scalar order ([`key_order`]); numbers
/// print in the shortest form that reads back to the same double ([`number_text`]); slashes are
/// not escaped. `pretty` is the `JSONSerialization` `.prettyPrinted` layout the checked-in files
/// use (`"key" : value`, two-space indent, an empty container as an open line, a blank line and
/// the close).
pub fn json_text(value: &Value, pretty: bool) -> Result<String, OpError> {
    let mut out = String::new();
    write(value, pretty, 0, &mut out)?;
    Ok(out)
}

fn write(value: &Value, pretty: bool, indent: usize, out: &mut String) -> Result<(), OpError> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => out.push_str(&number_text(number)?),
        Value::String(text) => quote(text, out),
        Value::Array(items) => {
            container(('[', ']'), items.iter(), pretty, indent, out, |item, out| {
                write(item, pretty, indent + 1, out)
            })?;
        }
        Value::Object(members) => {
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort_by(|a, b| key_order(a, b));
            container(('{', '}'), keys.into_iter(), pretty, indent, out, |key, out| {
                quote(key, out);
                out.push_str(if pretty { " : " } else { ":" });
                write(&members[key], pretty, indent + 1, out)
            })?;
        }
    }
    Ok(())
}

fn container<T>(
    (open, close): (char, char),
    items: impl ExactSizeIterator<Item = T>,
    pretty: bool,
    indent: usize,
    out: &mut String,
    mut element: impl FnMut(T, &mut String) -> Result<(), OpError>,
) -> Result<(), OpError> {
    let empty = items.len() == 0;
    out.push(open);
    let inner = "  ".repeat(indent + 1);
    for (index, item) in items.enumerate() {
        if index > 0 {
            out.push(',');
        }
        if pretty {
            out.push('\n');
            out.push_str(&inner);
        }
        element(item, out)?;
    }
    if pretty {
        out.push_str(if empty { "\n\n" } else { "\n" });
        out.push_str(&"  ".repeat(indent));
    }
    out.push(close);
    Ok(())
}

/// Swift `DeterministicJSON.keyOrder`: case-insensitive, ties broken by exact scalar order (the
/// order `JSONSerialization` `.sortedKeys` gave the checked-in files).
pub fn key_order(a: &str, b: &str) -> Ordering {
    let (lower_a, lower_b) = (a.to_lowercase(), b.to_lowercase());
    if lower_a != lower_b {
        return lower_a.cmp(&lower_b);
    }
    a.cmp(b)
}

/// A JSON number's text: an integer as itself, a double by [`double_text`].
pub fn number_text(number: &Number) -> Result<String, OpError> {
    if let Some(integer) = number.as_i64() {
        return Ok(integer.to_string());
    }
    if let Some(integer) = number.as_u64() {
        return Ok(integer.to_string());
    }
    double_text(number.as_f64().unwrap_or(f64::NAN))
}

/// Swift `DeterministicJSON.number`: the shortest decimal text that reads back to `value`. Whole
/// numbers below 1e15 print without a fraction (`1`, not `1.0`); the rest as Swift's round-trip
/// `description` does (`0.1`, `1e16` as `1e+16`, below 1e-4 or above 2^54 in exponent form),
/// with the exponent's sign and padding dropped (`1e-7`, not `1e-07`).
pub fn double_text(value: f64) -> Result<String, OpError> {
    if !value.is_finite() {
        return Err(OpError::Invalid("JSON has no form for NaN or infinity".to_owned()));
    }
    if value == value.round() && value.abs() < 1e15 {
        return Ok((value as i64).to_string());
    }
    let magnitude = value.abs();
    if magnitude < 1e-4 || magnitude > 2f64.powi(54) {
        return Ok(format!("{value:e}"));
    }
    let text = value.to_string();
    Ok(if text.contains('.') { text } else { text + ".0" })
}

/// Swift `DeterministicJSON.quote`: `"`, `\`, and the control characters escaped; nothing else
/// (no `\/`, no `\u` for non-ASCII).
fn quote(text: &str, out: &mut String) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            control if (control as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", control as u32);
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

// MARK: - Surfaces

/// What a row's surfaces follow from (Swift `SettingDescriptor.surfacePlan`'s inputs).
#[derive(Debug, Clone, PartialEq)]
pub struct SurfaceFacts<'a> {
    pub key: &'a str,
    /// The exported kind (`toggle`, `choice`, ...).
    pub kind: &'a str,
    /// The reason the palette does not list the row (Swift `palette: .hidden(reason)`).
    pub palette_hidden: Option<&'a str>,
    /// The row is read by cmux-next (Swift `isShownInCmuxNext`).
    pub consumed_by_cmux_next: bool,
    pub agent_settable: bool,
}

impl<'a> SurfaceFacts<'a> {
    /// The facts in an export row or a `schema.surfaces` request.
    pub fn of(row: &'a Value) -> Result<SurfaceFacts<'a>, OpError> {
        let text = |name: &str| {
            row.get(name)
                .and_then(Value::as_str)
                .ok_or_else(|| OpError::Invalid(format!("expected a string `{name}`")))
        };
        let consumers = row
            .get("consumers")
            .and_then(Value::as_array)
            .ok_or_else(|| OpError::Invalid("expected an array `consumers`".to_owned()))?;
        Ok(SurfaceFacts {
            key: text("key")?,
            kind: text("kind")?,
            palette_hidden: row.get("palette_hidden").and_then(Value::as_str),
            consumed_by_cmux_next: consumers.iter().any(|consumer| consumer == CMUX_NEXT),
            agent_settable: row.get("agent_settable").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}

/// Swift `SettingSurfaceAvailability`: one surface's binding.
#[derive(Debug, Clone, Default)]
struct Surface {
    operations: Vec<&'static str>,
    aliases: Vec<&'static str>,
    app_operations: Vec<&'static str>,
    app_aliases: Vec<&'static str>,
    row: Option<String>,
    editor: Option<&'static str>,
    /// Defaults to whether there are operations.
    offered: Option<bool>,
    reason: Option<String>,
}

impl Surface {
    fn to_json(&self) -> Value {
        json!({
            "offered": self.offered.unwrap_or(!self.operations.is_empty()),
            "operations": self.operations,
            "aliases": self.aliases,
            "app_operations": self.app_operations,
            "app_aliases": self.app_aliases,
            "row": self.row,
            "editor": self.editor,
            "reason": self.reason,
        })
    }
}

/// Swift `SettingDescriptor.surfacePlan` as exported: the palette lists a toggle as an action and
/// any other kind as a value page, when the row is exposed and read by cmux-next; the CLI and the
/// socket offer every settings operation; MCP writes only `agent_settable` rows.
pub fn surfaces(facts: &SurfaceFacts) -> Value {
    let palette = match (facts.palette_hidden, facts.consumed_by_cmux_next) {
        (Some(reason), _) => Surface { reason: Some(reason.to_owned()), ..Surface::default() },
        (None, true) if facts.kind == "toggle" => Surface {
            operations: vec!["palette.toggleSetting"],
            row: Some(format!("setting:{}", facts.key)),
            editor: Some("toggle"),
            ..Surface::default()
        },
        // Choice, color, number and text rows are value pages in SettingsPaletteSource rather
        // than registered actions.
        (None, true) => Surface {
            row: Some(format!("setting:{}", facts.key)),
            editor: Some("options"),
            offered: Some(true),
            ..Surface::default()
        },
        (None, false) => {
            Surface { reason: Some("not_consumed_by_cmux_next".to_owned()), ..Surface::default() }
        }
    };
    let agent = facts.agent_settable;
    let mut mcp_operations = MCP_READ.to_vec();
    if agent {
        mcp_operations.extend(MCP_WRITE);
    }
    let cli = Surface {
        operations: CLI_OPERATIONS.to_vec(),
        aliases: RESET_ALIASES.to_vec(),
        ..Surface::default()
    };
    let mcp = Surface {
        operations: mcp_operations,
        aliases: if agent { RESET_ALIASES.to_vec() } else { Vec::new() },
        reason: (!agent).then(|| "agent_settable_false".to_owned()),
        ..Surface::default()
    };
    let socket = Surface {
        operations: CLI_OPERATIONS.to_vec(),
        app_operations: APP_OPERATIONS.to_vec(),
        app_aliases: RESET_ALIASES.to_vec(),
        ..Surface::default()
    };
    json!({
        "palette": palette.to_json(),
        "cli": cli.to_json(),
        "mcp": mcp.to_json(),
        "socket": socket.to_json(),
    })
}

// MARK: - Rows

fn parsed(text: &'static str, cell: &'static OnceLock<Value>) -> &'static Value {
    // The files are compiled in and parsed by the export tests on every run.
    cell.get_or_init(|| serde_json::from_str(text).unwrap_or_default())
}

fn row_facts() -> &'static Value {
    static FACTS: OnceLock<Value> = OnceLock::new();
    parsed(ROW_FACTS, &FACTS)
}

fn sample_sets() -> &'static Value {
    static SETS: OnceLock<Value> = OnceLock::new();
    parsed(SAMPLES, &SETS)
}

/// How another validator checks a row (Swift `SettingsSchema.validationByKey`, then
/// `validationByKind`, then `defaultValidation`).
pub fn validation(key: &str, kind: &str) -> &'static str {
    let table = &row_facts()["validation"];
    table["keys"][key]
        .as_str()
        .or_else(|| table["kinds"][kind].as_str())
        .or_else(|| table["default"].as_str())
        .unwrap_or("portable")
}

/// Swift `SettingsSchema.keptOnResetAll`: Reset All Settings leaves the key alone.
pub fn kept_on_reset_all(key: &str) -> bool {
    row_facts()["kept_on_reset_all"]
        .as_array()
        .is_some_and(|keys| keys.iter().any(|kept| kept == key))
}

/// Swift `SettingsSchemaSamples.samples(row:)`: the values an exported row lists to accept and to
/// refuse, before the row's validator filters them: its validation domain's set, else its kind's
/// (`choice_list` for a `string_list` row with choices), with each `{"$sample": NAME}` filled
/// from the row's choices, range and `url_key`.
pub fn samples(row: &Map<String, Value>) -> (Vec<Value>, Vec<Value>) {
    let kind = row.get("kind").and_then(Value::as_str).unwrap_or("");
    let name =
        if kind == "string_list" && row.contains_key("choices") { "choice_list" } else { kind };
    let sets = sample_sets();
    let set = row
        .get("validation")
        .and_then(Value::as_str)
        .and_then(|domain| sets["domains"].get(domain))
        .or_else(|| sets["kinds"].get(name));
    let Some(set) = set else { return (Vec::new(), Vec::new()) };
    let choices: Vec<&str> = row
        .get("choices")
        .and_then(Value::as_array)
        .map(|choices| choices.iter().filter_map(|choice| choice["value"].as_str()).collect())
        .unwrap_or_default();
    let range = row.get("range");
    let bound = |name: &str| range.and_then(|range| range[name].as_f64()).unwrap_or(0.0);
    let (low, high) = (bound("min"), bound("max"));
    let span = (high - low).max(1.0);
    let url_key = row.get("url_key").and_then(Value::as_str).unwrap_or("");
    let values = |name: &str| -> Vec<Value> {
        let string = |text: &str| Value::String(text.to_owned());
        match name {
            "choices" => choices.iter().map(|choice| string(choice)).collect(),
            "choices_reversed" => choices.iter().rev().map(|choice| string(choice)).collect(),
            "first_choice" => vec![string(choices.first().copied().unwrap_or("a"))],
            "min" => vec![number_value(low)],
            "max" => vec![number_value(high)],
            "mid" => vec![number_value(low + (high - low) / 2.0)],
            "below" => vec![number_value(low - span)],
            "above" => vec![number_value(high + span)],
            "url_key" => vec![string(url_key)],
            _ => Vec::new(),
        }
    };
    // A placeholder in a list stands for its values; `$url_key` names the row's url_key member.
    fn fill(value: &Value, values: &dyn Fn(&str) -> Vec<Value>, url_key: &str) -> Vec<Value> {
        match value {
            Value::Object(members) => {
                if members.len() == 1
                    && let Some(Value::String(name)) = members.get("$sample")
                {
                    return values(name);
                }
                let filled = members
                    .iter()
                    .map(|(key, member)| {
                        let key = if key == "$url_key" { url_key.to_owned() } else { key.clone() };
                        (
                            key,
                            fill(member, values, url_key).into_iter().next().unwrap_or(Value::Null),
                        )
                    })
                    .collect();
                vec![Value::Object(filled)]
            }
            Value::Array(items) => {
                vec![Value::Array(
                    items.iter().flat_map(|item| fill(item, values, url_key)).collect(),
                )]
            }
            other => vec![other.clone()],
        }
    }
    let list = |name: &str| -> Vec<Value> {
        set[name]
            .as_array()
            .map(|items| items.iter().flat_map(|item| fill(item, &values, url_key)).collect())
            .unwrap_or_default()
    };
    (list("accept"), list("refuse"))
}

/// Swift `SettingsSchemaExport.row(for:text:)`'s derived members, on the descriptor's own row:
/// `surfaces` (from `palette_hidden`, which the export does not keep), `validation`,
/// `kept_on_reset_all`, `pattern` for an app id row, and the samples the row's validator
/// ([`accepts`], Swift `SettingDescriptor.accepts`) accepts and refuses.
pub fn export_row(mut row: Map<String, Value>) -> Result<Value, OpError> {
    let facts = Value::Object(row.clone());
    let surfaces = surfaces(&SurfaceFacts::of(&facts)?);
    row.remove("palette_hidden");
    let key = facts["key"].as_str().unwrap_or_default();
    let kind = facts["kind"].as_str().unwrap_or_default();
    let validation = validation(key, kind);
    row.insert("surfaces".to_owned(), surfaces);
    row.insert("validation".to_owned(), json!(validation));
    row.insert("kept_on_reset_all".to_owned(), json!(kept_on_reset_all(key)));
    if validation == "domain:app_id" {
        row.insert("pattern".to_owned(), row_facts()["app_id_pattern"].clone());
    }
    let (accept, refuse) = samples(&row);
    row.insert("accepts".to_owned(), json!([]));
    row.insert("refuses".to_owned(), json!([]));
    let parsed = Row::from_export(Value::Object(row.clone()))
        .map_err(|error| OpError::Invalid(format!("row {key}: {error}")))?;
    let accepted: Vec<Value> = accept.into_iter().filter(|value| accepts(&parsed, value)).collect();
    let refused: Vec<Value> = refuse.into_iter().filter(|value| !accepts(&parsed, value)).collect();
    row.insert("accepts".to_owned(), Value::Array(accepted));
    row.insert("refuses".to_owned(), Value::Array(refused));
    Ok(Value::Object(row))
}

/// Swift `SettingsSchemaExport.MissingKeys`: the catalog keys the document's texts (`{text, key}`)
/// name that `catalog` lacks, sorted. Settings values (defaults, samples, shapes) hold no texts.
pub fn missing_keys(document: &Value, catalog: &BTreeSet<&str>) -> Vec<String> {
    fn walk(value: &Value, catalog: &BTreeSet<&str>, missing: &mut BTreeSet<String>) {
        match value {
            Value::Object(members) => {
                if members.len() == 2
                    && members.get("text").is_some_and(Value::is_string)
                    && let Some(Value::String(key)) = members.get("key")
                {
                    if !catalog.contains(key.as_str()) {
                        missing.insert(key.clone());
                    }
                    return;
                }
                for (name, member) in members {
                    if !VALUE_MEMBERS.contains(&name.as_str()) {
                        walk(member, catalog, missing);
                    }
                }
            }
            Value::Array(items) => items.iter().for_each(|item| walk(item, catalog, missing)),
            _ => {}
        }
    }
    let mut missing = BTreeSet::new();
    walk(document, catalog, &mut missing);
    missing.into_iter().collect()
}

#[cfg(test)]
#[path = "schema_export_tests.rs"]
mod tests;
