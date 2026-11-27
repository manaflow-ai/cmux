//! The published MDM schema (docs/mdm), generated from the settings catalog
//! plus the managed policy keys (Swift `ManagedPreferencesManifest` and its
//! `+Docs`): a new setting is manageable the moment it is in the schema.
//! Output is deterministic and byte-for-byte what Foundation's property list
//! writer and `DeterministicJSON` wrote; the tests compare it with the
//! checked-in files.

use std::collections::BTreeMap;

use serde_json::{Map, Number, Value};

use super::{DOMAIN, POLICY_KEYS, PolicyType};
use crate::schema::Schema;

pub const TITLE: &str = "cmux";
pub const SUMMARY: &str = "Managed settings for cmux (every channel). Keys are cmux.json key paths; capitalized keys are policy keys. Forced values lock the setting; non-forced values replace its default. Exception: agents.chats.roots adds locked roots to the user list; agents.chats.enabled and agents.chats.discovery can only be forced off.";
/// Bump with any change to the generated schema (ProfileManifests `pfm_version`).
pub const VERSION: i64 = 2;
/// Fixed so the output is reproducible (1_791_244_800 s since 1970); update with `VERSION`.
pub const LAST_MODIFIED: &str = "2026-10-06T00:00:00Z";

/// The admin-documentation header: every line before the key rows.
const DOC_HEADER: [&str; 16] = [
    r#"# cmux managed preferences"#,
    r#""#,
    r#"Generated from the cmux settings catalog by `ManagedPreferencesManifest` (CmuxNextSettings). Do not edit by hand; run `CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests` in `Packages/macOS/CmuxNext`."#,
    r#""#,
    r#"Domain: `com.manaflow.cmux` for every channel (stable, NIGHTLY, DEV). A forced value (any MDM custom settings payload) locks the setting and Settings shows "Managed by your organization". A non-forced value replaces the default and the user can still change it. Precedence, highest first: MDM forced, team policy enforced, the user's cmux.json, MDM non-forced, team policy default, product default."#,
    r#""#,
    r#"Chat privacy exceptions: `agents.chats.roots` is the union of user roots and roots added by managed or team layers, deduplicated in layer order. Managed roots are locked rows, but users may still edit their own roots. `agents.chats.enabled` and `agents.chats.discovery` default to true; a forced false from either MDM or team policy turns them off, while a forced true never overrides a user false. Recommended booleans only supply missing user values. All three keys refuse agent writes (`privacy`). Managed chat roots and forced-off values are enforced while the cmux app runs; the acpmux daemon keeps the last values the app sent in its own `chat-settings.json`, so a daemon started without the app uses those values."#,
    r#""#,
    r#"Chat roots must be absolute harness data folders. The root folder, home folder, Desktop, Documents, Downloads, Pictures, Music, Movies, Library/Mobile Documents, Library/CloudStorage, Library/Containers, Library/Group Containers, Library/Mail, Library/Messages, Library/Safari, Library/Calendars and their descendants are refused, as are /Volumes, /Network and /net. Checks are case-insensitive and include symbolic links. Refused roots remain visible with a reason, but are never read or sent to the daemon. The protected list mirrors acpmux protected_folders.rs."#,
    r#""#,
    r#"The legacy forced keys `DisableAutoUpdate` and `DisableTelemetry` in `com.cmuxterm.app` keep working."#,
    r#""#,
    r#"Files: `com.manaflow.cmux.plist` (ProfileManifests: iMazing Profile Editor, ProfileCreator), `com.manaflow.cmux.json` (Jamf Pro custom schema), `cmux-example.mobileconfig` (any MDM), `com.manaflow.cmux.intune.plist` (Intune preference file)."#,
    r#""#,
    r#"| Key | Type | Default | Allowed values | Description |"#,
    r#"| --- | --- | --- | --- | --- |"#,
];

/// The files `docs/mdm` holds, by name.
pub const FILES: [&str; 5] = [
    "com.manaflow.cmux.plist",
    "com.manaflow.cmux.json",
    "cmux-example.mobileconfig",
    "com.manaflow.cmux.intune.plist",
    "managed-preferences.md",
];

/// One manageable key.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub name: String,
    pub title: String,
    pub help: String,
    /// `boolean`, `string`, `real`, `array` or `dictionary`.
    pub ty: &'static str,
    pub choices: Vec<String>,
    pub range: Option<(f64, f64)>,
    pub default: Option<Value>,
    pub members: Vec<String>,
    /// `json` rows: the value's JSON Schema (the Jamf schema uses it as is).
    pub shape: Option<Value>,
}

fn text(row: &Value, key: &str) -> String {
    row.get(key).and_then(|t| t.get("text")).and_then(Value::as_str).unwrap_or_default().to_string()
}

fn choices(row: &Value) -> Vec<String> {
    row.get("choices")
        .and_then(Value::as_array)
        .map(|c| {
            c.iter()
                .filter_map(|c| c.get("value").and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn bound(row: &Value, side: &str) -> f64 {
    row.get("range").and_then(|r| r.get(side)).and_then(Value::as_f64).unwrap_or_default()
}

/// Swift `Int(Double)` truncates toward zero.
fn whole(value: f64) -> i64 {
    value as i64
}

/// The settings cmux-next reads (rows whose consumers include it), then the
/// policy keys.
pub fn entries(schema: &Schema) -> Vec<Entry> {
    let mut out = Vec::new();
    for row in &schema.rows {
        let row = row.raw();
        let consumers = row.get("consumers").and_then(Value::as_array);
        if !consumers.is_some_and(|c| c.iter().any(|c| c.as_str() == Some("cmux-next"))) {
            continue;
        }
        let help = text(&row, "help");
        let more = if help.is_empty() { "" } else { " " };
        let mut entry = Entry {
            name: row.get("key").and_then(Value::as_str).unwrap_or_default().to_string(),
            title: text(&row, "title"),
            help: help.clone(),
            ty: "string",
            choices: Vec::new(),
            range: None,
            default: row.get("default").filter(|d| !d.is_null()).cloned(),
            members: Vec::new(),
            shape: None,
        };
        match row.get("kind").and_then(Value::as_str).unwrap_or_default() {
            "choice" => entry.choices = choices(&row),
            "choice_or_number" => {
                entry.choices = choices(&row);
                entry.help = format!(
                    "{help}{more}Also accepts a number from {} to {} in a raw profile.",
                    whole(bound(&row, "min")),
                    whole(bound(&row, "max"))
                );
            }
            "choice_or_url" => {
                entry.choices = choices(&row);
                let url_key = row.get("url_key").and_then(Value::as_str).unwrap_or_default();
                entry.help = format!(
                    "{help}{more}Also accepts a dictionary {{\"{url_key}\": \"http(s)://host[:port]\"}} in a raw profile."
                );
            }
            "toggle" => entry.ty = "boolean",
            "number" => {
                entry.ty = "real";
                entry.range = Some((bound(&row, "min"), bound(&row, "max")));
            }
            "color" | "sound" | "url" | "theme" | "font_family" | "text" => {}
            "host_list" | "folder_list" | "number_list" => entry.ty = "array",
            "string_list" => {
                entry.ty = "array";
                entry.choices = choices(&row);
            }
            "time_range" => {
                entry.ty = "dictionary";
                entry.members = vec!["start".into(), "end".into()];
            }
            "string_map" | "sound_rules" => entry.ty = "dictionary",
            "json" => {
                entry.help =
                    format!("{help}{more}Nested; see `cmux settings schema` for its shape.");
                let shape = row.get("shape").cloned().unwrap_or(Value::Null);
                entry.ty = if shape.get("type").and_then(Value::as_str) == Some("object") {
                    "dictionary"
                } else {
                    "array"
                };
                entry.shape = Some(shape);
            }
            _ => continue,
        }
        out.push(entry);
    }
    for key in &POLICY_KEYS {
        let (ty, choices): (&'static str, Vec<String>) = match key.ty {
            PolicyType::String => ("string", Vec::new()),
            PolicyType::Boolean => ("boolean", Vec::new()),
            PolicyType::Choice(values) => {
                ("string", values.iter().map(|v| v.to_string()).collect())
            }
            PolicyType::StringArray(values) => {
                ("array", values.iter().map(|v| v.to_string()).collect())
            }
        };
        out.push(Entry {
            name: key.name.into(),
            title: key.name.into(),
            help: key.help.into(),
            ty,
            choices,
            range: None,
            default: None,
            members: Vec::new(),
            shape: None,
        });
    }
    out
}

// Property lists (Foundation's XML writer) --------------------------------

/// A property list value.
#[derive(Debug, Clone, PartialEq)]
enum Plist {
    Bool(bool),
    Str(String),
    Int(i64),
    Real(f64),
    Date(&'static str),
    Array(Vec<Plist>),
    Dict(BTreeMap<String, Plist>),
}

/// A JSON value as a property list object (null has no plist form); whole
/// numbers below 1e15 become integers.
fn to_plist(value: &Value) -> Option<Plist> {
    Some(match value {
        Value::Null => return None,
        Value::Bool(b) => Plist::Bool(*b),
        Value::Number(n) => {
            let x = n.as_f64().unwrap_or_default();
            if x.round() == x && x.abs() < 1e15 { Plist::Int(x as i64) } else { Plist::Real(x) }
        }
        Value::String(s) => Plist::Str(s.clone()),
        Value::Array(items) => Plist::Array(items.iter().filter_map(to_plist).collect()),
        Value::Object(members) => Plist::Dict(
            members.iter().filter_map(|(k, v)| Some((k.clone(), to_plist(v)?))).collect(),
        ),
    })
}

/// The same normalisation as JSON: whole numbers below 1e15 are integers.
fn normalized(value: &Value) -> Option<Value> {
    Some(match value {
        Value::Null => return None,
        Value::Number(n) => {
            let x = n.as_f64().unwrap_or_default();
            if x.round() == x && x.abs() < 1e15 {
                Value::from(x as i64)
            } else {
                Value::Number(Number::from_f64(x)?)
            }
        }
        Value::Array(items) => Value::Array(items.iter().filter_map(normalized).collect()),
        Value::Object(members) => Value::Object(
            members.iter().filter_map(|(k, v)| Some((k.clone(), normalized(v)?))).collect(),
        ),
        other => other.clone(),
    })
}

const HEADER: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n";

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// C's `%.17g`, which CoreFoundation prints reals with.
fn real_text(value: f64) -> String {
    if value == 0.0 {
        return "0.0".into();
    }
    let sci = format!("{value:.16e}");
    let (mantissa, exponent) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    if !(-4..17).contains(&exponent) {
        let mantissa = mantissa.trim_end_matches('0').trim_end_matches('.');
        let sign = if exponent < 0 { '-' } else { '+' };
        return format!("{mantissa}e{sign}{:02}", exponent.abs());
    }
    let decimals = (16 - exponent).max(0) as usize;
    let text = format!("{value:.decimals$}");
    if text.contains('.') {
        text.trim_end_matches('0').trim_end_matches('.').to_string()
    } else {
        text
    }
}

fn write_plist(value: &Plist, depth: usize, out: &mut Vec<String>) {
    let tabs = "\t".repeat(depth);
    match value {
        Plist::Bool(b) => out.push(format!("{tabs}{}", if *b { "<true/>" } else { "<false/>" })),
        Plist::Date(d) => out.push(format!("{tabs}<date>{d}</date>")),
        Plist::Str(s) => out.push(format!("{tabs}<string>{}</string>", escape(s))),
        Plist::Real(x) => out.push(format!("{tabs}<real>{}</real>", real_text(*x))),
        Plist::Int(i) => out.push(format!("{tabs}<integer>{i}</integer>")),
        Plist::Array(items) if items.is_empty() => out.push(format!("{tabs}<array/>")),
        Plist::Array(items) => {
            out.push(format!("{tabs}<array>"));
            for item in items {
                write_plist(item, depth + 1, out);
            }
            out.push(format!("{tabs}</array>"));
        }
        Plist::Dict(members) if members.is_empty() => out.push(format!("{tabs}<dict/>")),
        Plist::Dict(members) => {
            out.push(format!("{tabs}<dict>"));
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
            for key in keys {
                out.push(format!("{tabs}\t<key>{}</key>", escape(key)));
                write_plist(&members[key], depth + 1, out);
            }
            out.push(format!("{tabs}</dict>"));
        }
    }
}

fn plist_xml(value: &Plist) -> String {
    let mut out = Vec::new();
    write_plist(value, 0, &mut out);
    format!("{HEADER}{}\n</plist>\n", out.join("\n"))
}

// Deterministic JSON (Swift `DeterministicJSON`) --------------------------

/// The shortest round-trip form of a finite double, as Python's `repr` laid
/// it out: positional for exponents -4..16, `1e-05` style otherwise.
fn shortest(value: f64) -> String {
    let sci = format!("{value:e}");
    let (mantissa, exponent) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    if (-4..16).contains(&exponent) {
        let text = format!("{value}");
        return if text.contains('.') { text } else { format!("{text}.0") };
    }
    let sign = if exponent < 0 { "-" } else { "+" };
    format!("{mantissa}e{sign}{:02}", exponent.abs())
}

fn json_number(n: &Number) -> String {
    if let Some(i) = n.as_i64() {
        return i.to_string();
    }
    let x = n.as_f64().unwrap_or_default();
    if x.round() == x && x.abs() < 1e15 {
        return (x as i64).to_string();
    }
    let text = shortest(x);
    match text.split_once('e') {
        Some((mantissa, exponent)) => {
            format!("{mantissa}e{}", exponent.parse::<i32>().unwrap_or_default())
        }
        None => text,
    }
}

fn quote(text: &str) -> String {
    let mut out = String::from("\"");
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn container(open: char, close: char, items: Vec<String>, pretty: bool, indent: usize) -> String {
    let mut out = String::from(open);
    let inner = "  ".repeat(indent + 1);
    let empty = items.is_empty();
    for (index, item) in items.into_iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        if pretty {
            out.push('\n');
            out.push_str(&inner);
        }
        out.push_str(&item);
    }
    if pretty {
        out.push_str(if empty { "\n\n" } else { "\n" });
        out.push_str(&"  ".repeat(indent));
    }
    out.push(close);
    out
}

/// `DeterministicJSON.string(_, pretty:)`: `"key" : value`, two-space indent,
/// keys in case-insensitive order (ties by exact order).
pub fn deterministic_json(value: &Value, pretty: bool, indent: usize) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => json_number(n),
        Value::String(s) => quote(s),
        Value::Array(items) => container(
            '[',
            ']',
            items.iter().map(|v| deterministic_json(v, pretty, indent + 1)).collect(),
            pretty,
            indent,
        ),
        Value::Object(members) => {
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort_by(|a, b| {
                (a.to_lowercase(), a.as_str()).cmp(&(b.to_lowercase(), b.as_str()))
            });
            let separator = if pretty { " : " } else { ":" };
            container(
                '{',
                '}',
                keys.into_iter()
                    .map(|k| {
                        format!(
                            "{}{separator}{}",
                            quote(k),
                            deterministic_json(&members[k], pretty, indent + 1)
                        )
                    })
                    .collect(),
                pretty,
                indent,
            )
        }
    }
}

/// `JSONValue.compactText`: members in key order, no spaces.
fn compact_text(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => {
            let x = n.as_f64().unwrap_or_default();
            if x.round() == x && x.abs() < 1e15 { (x as i64).to_string() } else { swift_double(x) }
        }
        Value::String(s) => quote(s),
        Value::Array(items) => {
            format!("[{}]", items.iter().map(compact_text).collect::<Vec<_>>().join(","))
        }
        Value::Object(members) => {
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort();
            format!(
                "{{{}}}",
                keys.into_iter()
                    .map(|k| format!("{}:{}", quote(k), compact_text(&members[k])))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
    }
}

/// Swift's `String(Double)`: the shortest round trip, `1e-05` style exponents.
fn swift_double(value: f64) -> String {
    let text = shortest(value);
    match text.split_once('e') {
        Some((mantissa, exponent)) => {
            let sign = if exponent.starts_with('-') { "-" } else { "" };
            let digits = exponent.trim_start_matches(['+', '-']).trim_start_matches('0');
            let digits = if digits.is_empty() { "0" } else { digits };
            format!("{mantissa}e{sign}{digits:0>2}")
        }
        None => text,
    }
}

fn format_number(value: f64) -> String {
    if value.round() == value { (value as i64).to_string() } else { swift_double(value) }
}

// The five files -----------------------------------------------------------

/// ProfileManifests (iMazing Profile Editor, ProfileCreator).
pub fn profile_manifest(entries: &[Entry]) -> String {
    let mut subkeys = Vec::new();
    for e in entries {
        let mut key: BTreeMap<String, Plist> = BTreeMap::new();
        key.insert("pfm_name".into(), Plist::Str(e.name.clone()));
        key.insert("pfm_title".into(), Plist::Str(e.title.clone()));
        key.insert("pfm_type".into(), Plist::Str(e.ty.into()));
        if !e.help.is_empty() {
            key.insert("pfm_description".into(), Plist::Str(e.help.clone()));
        }
        if let Some(value) = e.default.as_ref().and_then(to_plist) {
            key.insert("pfm_default".into(), value);
        }
        let list = |items: &[String]| Plist::Array(items.iter().cloned().map(Plist::Str).collect());
        if e.ty == "array" {
            // A nested list (a `json` row) holds lists.
            let nested = e
                .shape
                .as_ref()
                .and_then(|s| s.get("items"))
                .and_then(|i| i.get("type"))
                .and_then(Value::as_str)
                == Some("array");
            let mut item = BTreeMap::new();
            item.insert("pfm_name".to_string(), Plist::Str("Item".into()));
            item.insert(
                "pfm_type".to_string(),
                Plist::Str(if nested { "array" } else { "string" }.into()),
            );
            if !e.choices.is_empty() {
                item.insert("pfm_range_list".into(), list(&e.choices));
            }
            key.insert("pfm_subkeys".into(), Plist::Array(vec![Plist::Dict(item)]));
        } else if !e.choices.is_empty() {
            key.insert("pfm_range_list".into(), list(&e.choices));
        }
        if let Some((min, max)) = e.range {
            key.insert("pfm_range_min".into(), Plist::Real(min));
            key.insert("pfm_range_max".into(), Plist::Real(max));
        }
        if !e.members.is_empty() {
            let members = e
                .members
                .iter()
                .map(|m| {
                    Plist::Dict(BTreeMap::from([
                        ("pfm_name".to_string(), Plist::Str(m.clone())),
                        ("pfm_type".to_string(), Plist::Str("string".into())),
                        ("pfm_description".to_string(), Plist::Str("HH:MM".into())),
                    ]))
                })
                .collect();
            key.insert("pfm_subkeys".into(), Plist::Array(members));
        }
        subkeys.push(Plist::Dict(key));
    }
    let manifest = BTreeMap::from([
        ("pfm_domain".to_string(), Plist::Str(DOMAIN.into())),
        ("pfm_title".to_string(), Plist::Str(TITLE.into())),
        ("pfm_description".to_string(), Plist::Str(SUMMARY.into())),
        ("pfm_format_version".to_string(), Plist::Int(1)),
        ("pfm_version".to_string(), Plist::Int(VERSION)),
        ("pfm_last_modified".to_string(), Plist::Date(LAST_MODIFIED)),
        ("pfm_platforms".to_string(), Plist::Array(vec![Plist::Str("macOS".into())])),
        (
            "pfm_targets".to_string(),
            Plist::Array(vec![Plist::Str("user".into()), Plist::Str("system".into())]),
        ),
        ("pfm_unique".to_string(), Plist::Bool(true)),
        ("pfm_subkeys".to_string(), Plist::Array(subkeys)),
    ]);
    plist_xml(&Plist::Dict(manifest))
}

/// Jamf Pro (Application & Custom Settings, custom schema), with its trailing newline.
pub fn jamf_schema(entries: &[Entry]) -> String {
    let mut properties = Map::new();
    for e in entries {
        let mut p = Map::new();
        p.insert("title".into(), Value::from(e.title.clone()));
        p.insert(
            "description".into(),
            Value::from(if e.help.is_empty() { e.name.clone() } else { e.help.clone() }),
        );
        if let Some(Value::Object(rules)) = &e.shape {
            // A nested value: its own JSON Schema, as the daemon checks it.
            for (rule, value) in rules {
                match normalized(value) {
                    Some(v) => p.insert(rule.clone(), v),
                    None => p.remove(rule),
                };
            }
            properties.insert(e.name.clone(), Value::Object(p));
            continue;
        }
        let strings =
            |items: &[String]| Value::Array(items.iter().cloned().map(Value::from).collect());
        match e.ty {
            "boolean" => {
                p.insert("type".into(), "boolean".into());
            }
            "string" => {
                p.insert("type".into(), "string".into());
            }
            "real" => {
                p.insert("type".into(), "number".into());
            }
            "array" => {
                p.insert("type".into(), "array".into());
                let mut items = Map::new();
                items.insert("type".into(), "string".into());
                if !e.choices.is_empty() {
                    items.insert("enum".into(), strings(&e.choices));
                }
                p.insert("items".into(), Value::Object(items));
            }
            _ => {
                p.insert("type".into(), "object".into());
                let members = e
                    .members
                    .iter()
                    .map(|m| (m.clone(), serde_json::json!({"type": "string", "title": m})))
                    .collect();
                p.insert("properties".into(), Value::Object(members));
            }
        }
        if e.ty != "array" && !e.choices.is_empty() {
            p.insert("enum".into(), strings(&e.choices));
        }
        if let Some((min, max)) = e.range {
            p.insert("minimum".into(), Number::from_f64(min).into());
            p.insert("maximum".into(), Number::from_f64(max).into());
        }
        if let Some(value) = e.default.as_ref().and_then(normalized) {
            p.insert("default".into(), value);
        }
        properties.insert(e.name.clone(), Value::Object(p));
    }
    let schema = serde_json::json!({
        "title": format!("{TITLE} ({DOMAIN})"),
        "description": SUMMARY,
        "properties": Value::Object(properties),
    });
    format!("{}\n", deterministic_json(&schema, true, 0))
}

/// The keys the example profile sets: the first three catalog entries and the
/// App Store toggle, each at its default, so installing the example as-is
/// locks those settings without changing them.
fn example_keys(entries: &[Entry]) -> BTreeMap<String, Plist> {
    let mut keys = BTreeMap::new();
    for e in entries.iter().take(3) {
        if let Some(value) = e.default.as_ref().and_then(to_plist) {
            keys.insert(e.name.clone(), value);
        }
    }
    if let Some(app_store) = entries.iter().find(|e| e.name == "labs.appStore")
        && let Some(value) = app_store.default.as_ref().and_then(to_plist)
    {
        keys.insert(app_store.name.clone(), value);
    }
    keys.insert("DisabledFeatures".into(), Plist::Array(Vec::new()));
    keys
}

/// An unsigned profile with one `com.manaflow.cmux` payload. Fixed UUIDs keep
/// it reproducible; replace them (and the keys) before deploying.
pub fn example_mobileconfig(entries: &[Entry]) -> String {
    let mut payload = example_keys(entries);
    let text = |s: &str| Plist::Str(s.into());
    for (key, value) in [
        ("PayloadType", text(DOMAIN)),
        ("PayloadVersion", Plist::Int(1)),
        ("PayloadIdentifier", text("com.manaflow.cmux.example.settings")),
        ("PayloadUUID", text("5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E01")),
        ("PayloadDisplayName", text("cmux settings")),
    ] {
        // The example key wins, as `merging { first, _ in first }` has it.
        payload.entry(key.to_string()).or_insert(value);
    }
    let profile = BTreeMap::from([
        ("PayloadType".to_string(), text("Configuration")),
        ("PayloadVersion".to_string(), Plist::Int(1)),
        ("PayloadIdentifier".to_string(), text("com.manaflow.cmux.example")),
        ("PayloadUUID".to_string(), text("5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E00")),
        ("PayloadDisplayName".to_string(), text("cmux (example)")),
        (
            "PayloadDescription".to_string(),
            text(
                "Example managed settings for cmux. Generated from the settings catalog; see managed-preferences.md.",
            ),
        ),
        ("PayloadScope".to_string(), text("System")),
        ("PayloadContent".to_string(), Plist::Array(vec![Plist::Dict(payload)])),
    ]);
    plist_xml(&Plist::Dict(profile))
}

/// Intune "Preference file": bare keys, no `<plist>` or `<dict>` wrapper.
pub fn intune_preference_file(entries: &[Entry]) -> String {
    let xml = plist_xml(&Plist::Dict(example_keys(entries)));
    let (Some(start), Some(end)) = (xml.find("<dict>\n"), xml.rfind("</dict>\n</plist>")) else {
        return xml;
    };
    xml[start + "<dict>\n".len()..end]
        .split('\n')
        .map(|line| line.strip_prefix('\t').unwrap_or(line))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The admin documentation, `docs/mdm/managed-preferences.md`.
pub fn markdown(entries: &[Entry]) -> String {
    let mut lines: Vec<String> = DOC_HEADER.iter().map(|l| l.to_string()).collect();
    for e in entries {
        let allowed = if !e.choices.is_empty() {
            e.choices.iter().map(|c| format!("`{c}`")).collect::<Vec<_>>().join(", ")
        } else if let Some((min, max)) = e.range {
            format!("{} to {}", format_number(min), format_number(max))
        } else if !e.members.is_empty() {
            e.members.iter().map(|m| format!("`{m}`: HH:MM")).collect::<Vec<_>>().join(", ")
        } else {
            String::new()
        };
        let fallback =
            e.default.as_ref().map(|d| format!("`{}`", compact_text(d))).unwrap_or_default();
        let help = e.help.replace('|', "\\|");
        let description = if e.title == e.name {
            help
        } else if help.is_empty() {
            e.title.clone()
        } else {
            format!("{}. {help}", e.title)
        };
        lines.push(format!("| `{}` | {} | {fallback} | {allowed} | {description} |", e.name, e.ty));
    }
    format!("{}\n", lines.join("\n"))
}

/// The five `docs/mdm` files, as `(name, text)`.
pub fn files(schema: &Schema) -> Vec<(&'static str, String)> {
    let entries = entries(schema);
    vec![
        (FILES[0], profile_manifest(&entries)),
        (FILES[1], jamf_schema(&entries)),
        (FILES[2], example_mobileconfig(&entries)),
        (FILES[3], intune_preference_file(&entries)),
        (FILES[4], markdown(&entries)),
    ]
}

#[cfg(test)]
#[path = "manifest_tests.rs"]
mod tests;
