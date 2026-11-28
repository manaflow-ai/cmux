//! plans/cmux-next/links.json: cmux-next's object links as data, for clients that make the same
//! links without being cmux-next. Each example is written by [`DeepLink::url`] and each rule by
//! the constants its validator uses; the schemes per build come from the caller (the app's
//! `CloudConfiguration`, which registers them).

use super::*;
use serde_json::{Map, Value, json};

/// The URL scheme one kind of build registers and writes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExportScheme {
    /// `release`, `nightly`, `rc`, `debug` or `tagged`.
    pub build: String,
    pub bundle_id: Option<String>,
    /// The scheme, or for `tagged` the one an example tag gives.
    pub scheme: String,
    /// For `tagged`: the tag the example scheme was made from.
    pub example_tag: Option<String>,
}

const EXAMPLE_HEX: &str = "0123456789abcdef0123456789abcdef";
const EXAMPLE_AGENT_SESSION: &str = "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d";

/// The export as pretty-printed, key-sorted JSON with a trailing newline, byte for byte as
/// Foundation's `JSONSerialization` writes it (`"key" : value`, two-space indent, `/` unescaped).
pub fn export_json(schemes: &[ExportScheme]) -> String {
    let scheme = schemes
        .iter()
        .find(|s| s.build == "release")
        .map_or("cmux", |s| s.scheme.as_str())
        .to_owned();
    let url = |link: DeepLink| link.url(&scheme).unwrap_or_default();
    let example = |target: Target| url(DeepLink::new(target));
    let resource_rule = format!("<prefix> + {RESOURCE_HEX_DIGITS} lowercase hex digits [0-9a-f]");
    let token_rule = format!(
        "{} to {} ASCII letters, digits, '-', '_' or '.'",
        TOKEN_LENGTHS.0, TOKEN_LENGTHS.1
    );
    let agent_session_rule = format!(
        "{} to {} ASCII letters, digits, '-', '_', '.', or ':'",
        AGENT_SESSION_LENGTHS.0, AGENT_SESSION_LENGTHS.1
    );
    let (short_lo, short_hi) = SHORT_TOKEN_LENGTHS;
    let agent =
        || Target::Agent { harness: "claude".into(), session: EXAMPLE_AGENT_SESSION.into() };
    let kinds = json!([
        {"kind": "workspace", "id_prefix": "ws_", "id_rule": resource_rule,
         "example": example(Target::Workspace(format!("ws_{EXAMPLE_HEX}")))},
        {"kind": "pane", "id_prefix": "pane_", "id_rule": resource_rule,
         "example": example(Target::Pane(format!("pane_{EXAMPLE_HEX}"))), "opens": "the pane's selected tab"},
        {"kind": "tab", "id_prefix": "tab_", "id_rule": resource_rule,
         "example": example(Target::Tab(format!("tab_{EXAMPLE_HEX}")))},
        {"kind": "session", "id_rule": format!("an acpmux session id: {token_rule}"),
         "turn": format!("optional fragment #{TURN_FRAGMENT_PREFIX}<turnId>; the turn id follows the same rule"),
         "example": example(Target::Session { id: "ses-01.example_a".into(), turn: None }),
         "example_with_turn": example(Target::Session { id: "ses-01.example_a".into(), turn: Some("turn_7".into()) })},
        {"kind": "agent", "path": "agent/<harness>/<session>",
         "id_rule": format!("harness: an acpmux harness name, {short_lo} to {short_hi} lowercase ASCII letters, digits or '-'; \
    session: the harness's own session id, {agent_session_rule}"),
         "hints": format!("optional ?{HOST_HINT_KEY}=<machine name>&{NAME_HINT_KEY}=<agent name>, for display only: \
    {short_lo} to {short_hi} characters of the session id rule; a malformed hint is dropped"),
         "message": format!("optional ?{MESSAGE_KEY}=<harness message id>, the session's own id for one message \
    ({token_rule}): the chat scrolls to it and marks it, and leaves the view where it is when its \
    transcript has no such message. A malformed or repeated one is dropped, never the link"),
         "schema": "schemas/deeplinks/agent-link.json states these parameters and their vectors for every emitter \
    and parser (cmux.com/deeplink/agent writes links by it)",
         "opens": "only a tab this app already shows the session in (the chat tab that adopted it, else the terminal \
    running it); it never starts, resumes or connects to anything",
         "example": example(agent()),
         "example_with_hints": url(DeepLink { host_hint: Some("build-mac".into()), name_hint: Some("Lanternfish".into()), ..DeepLink::new(agent()) }),
         "example_with_message": url(DeepLink { message: Some("msg_01hq9f4c7k".into()), ..DeepLink::new(agent()) })},
    ]);
    let rows: Vec<Value> = schemes
        .iter()
        .map(|s| {
            let mut row = Map::new();
            row.insert("build".into(), json!(s.build));
            row.insert("scheme".into(), json!(s.scheme));
            if let Some(bundle) = &s.bundle_id {
                row.insert("bundle_id".into(), json!(bundle));
            }
            if let Some(tag) = &s.example_tag {
                row.insert("example_tag".into(), json!(tag));
                row.insert(
                    "rule".into(),
                    json!("cmux-dev-<tag>, the tag lowercased, runs of [a-z0-9] joined by single hyphens"),
                );
            }
            Value::Object(row)
        })
        .collect();
    let root = json!({
        "description": "cmux-next object links (Copy Workspace/Pane/Tab Link, agent chat sessions, outside agent sessions), generated from \
    CmuxNextActions/DeepLink (DeepLink.url) and CloudConfiguration.callbackScheme. Do not edit: \
    CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter LinkExportTests rewrites it.",
        "shape": format!("<scheme>://<kind>/<id>[?machine=machine_<{RESOURCE_HEX_DIGITS} hex>][#{TURN_FRAGMENT_PREFIX}<turnId>, session only]"),
        "schemes": rows,
        "target_scheme": scheme,
        "target_scheme_rule": "A client that is not a shipping cmux build writes the release scheme, so the link opens the user's installed cmux.",
        "kinds": kinds,
        "machine": format!("optional ?machine=machine_<{RESOURCE_HEX_DIGITS} hex>: the machine the target lives on (a hint; ids are globally unique)"),
        "ignored": "every other query parameter is ignored, so a link never carries a command",
        "agent_tab": "Copy Tab Link on an agent chat tab writes its chat's session link (kind session, no turn), \
    not a tab link; a new chat with no session has no link",
        "not_links": [format!("{scheme}://{AUTH_CALLBACK_HOST} is the sign-in callback, never a link")],
    });
    let mut out = String::new();
    write_value(&root, 0, &mut out);
    out.push('\n');
    out
}

fn indent(depth: usize, out: &mut String) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

/// Foundation's pretty-printed, key-sorted JSON.
fn write_value(value: &Value, depth: usize, out: &mut String) {
    match value {
        Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{\n\n");
                indent(depth, out);
                out.push('}');
                return;
            }
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push_str("{\n");
            for (i, key) in keys.iter().enumerate() {
                indent(depth + 1, out);
                write_string(key, out);
                out.push_str(" : ");
                write_value(&map[key.as_str()], depth + 1, out);
                if i + 1 < keys.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(depth, out);
            out.push('}');
        }
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[\n\n");
                indent(depth, out);
                out.push(']');
                return;
            }
            out.push_str("[\n");
            for (i, item) in items.iter().enumerate() {
                indent(depth + 1, out);
                write_value(item, depth + 1, out);
                if i + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            indent(depth, out);
            out.push(']');
        }
        Value::String(text) => write_string(text, out),
        other => out.push_str(&other.to_string()),
    }
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
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
}
