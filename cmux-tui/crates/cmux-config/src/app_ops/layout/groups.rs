//! `workspaceGroups`: Swift `WorkspaceGroupConfig` and its parse.

use serde_json::{Map, Value, json};

use super::{Diag, OpError, at, diags_json, opt_string, root_of};

const PLACEMENTS: [&str; 3] = ["afterCurrent", "top", "end"];
const TOKENS: [&str; 9] =
    ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"];

pub(super) fn parse_op(request: &Value) -> Result<Value, OpError> {
    let (config, diags) = parse(root_of(request)?);
    Ok(json!({"config": config, "diagnostics": diags_json(&diags)}))
}

pub(super) fn key_op(request: &Value) -> Result<Value, OpError> {
    let directory = opt_string(request, "directory")?
        .ok_or_else(|| OpError::Invalid("expected `directory`".into()))?;
    let home =
        opt_string(request, "home")?.ok_or_else(|| OpError::Invalid("expected `home`".into()))?;
    Ok(json!({"key": key_for(directory, home)}))
}

pub(super) fn entry_op(request: &Value) -> Result<Value, OpError> {
    let home =
        opt_string(request, "home")?.ok_or_else(|| OpError::Invalid("expected `home`".into()))?;
    let config =
        request.get("config").ok_or_else(|| OpError::Invalid("expected `config`".into()))?;
    let directory = opt_string(request, "directory")?;
    let found = directory.and_then(|directory| entry_for(config, directory, home));
    let global = config.get("newWorkspacePlacement").filter(|p| p.is_string()).cloned();
    let own = found
        .as_ref()
        .and_then(|(_, entry)| entry.get("newWorkspacePlacement"))
        .filter(|p| p.is_string())
        .cloned();
    let configured = own.or(global);
    let placement = configured.clone().unwrap_or_else(|| json!("end"));
    let mut reply = Map::new();
    if let Some((key, entry)) = found {
        reply.insert("key".into(), json!(key));
        reply.insert("entry".into(), entry);
    }
    reply.insert("configuredPlacement".into(), configured.unwrap_or(Value::Null));
    reply.insert("placement".into(), placement);
    Ok(Value::Object(reply))
}

/// `workspaceGroups` from the file root: a missing key is the default with no diagnostic; a bad
/// value is dropped (the rest of its entry stays) with a diagnostic naming it.
pub(super) fn parse(root: &Value) -> (Value, Vec<Diag>) {
    let mut diags = Vec::new();
    let mut config = Map::new();
    config.insert("newWorkspacePlacement".into(), Value::Null);
    config.insert("byCwd".into(), json!({}));
    let Some(value) = at(root, &["workspaceGroups"]) else { return (Value::Object(config), diags) };
    let Some(object) = value.as_object() else {
        diags.push(Diag::invalid("workspaceGroups", "expected an object"));
        return (Value::Object(config), diags);
    };
    if let Some(raw) = object.get("newWorkspacePlacement")
        && let Some(placement) = placement(raw, "workspaceGroups.newWorkspacePlacement", &mut diags)
    {
        config.insert("newWorkspacePlacement".into(), json!(placement));
    }
    let Some(entries) = object.get("byCwd") else { return (Value::Object(config), diags) };
    let Some(by_cwd) = entries.as_object() else {
        diags.push(Diag::invalid(
            "workspaceGroups.byCwd",
            "expected an object of folder to group settings",
        ));
        return (Value::Object(config), diags);
    };
    let mut out = Map::new();
    for (key, raw) in by_cwd {
        let path = format!("workspaceGroups.byCwd.{key}");
        let Some(fields) = raw.as_object() else {
            diags.push(Diag::invalid(path, "expected an object"));
            continue;
        };
        out.insert(key.clone(), entry(fields, &path, &mut diags));
    }
    config.insert("byCwd".into(), Value::Object(out));
    (Value::Object(config), diags)
}

/// A group color wire: a palette token, `none` or `#RRGGBB` (`#RGB`, `#RRGGBB`, `#RRGGBBAA` in; the
/// alpha dropped, upper-case out).
fn tint_wire(wire: &str) -> Option<String> {
    if wire == "none" || TOKENS.contains(&wire) {
        return Some(wire.to_string());
    }
    if !wire.starts_with('#') {
        return None;
    }
    let (r, g, b, _) = crate::app_ops::layout::chrome::css_hex(wire)?;
    Some(format!("#{r:02X}{g:02X}{b:02X}"))
}

fn trim_blank(text: &str) -> &str {
    text.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r')
}

fn entry(fields: &Map<String, Value>, path: &str, diags: &mut Vec<Diag>) -> Value {
    let mut entry = Map::new();
    for key in ["color", "icon", "newWorkspacePlacement"] {
        entry.insert(key.into(), Value::Null);
    }
    entry.insert("contextMenu".into(), json!([]));
    if let Some(raw) = fields.get("color") {
        match raw.as_str().and_then(tint_wire) {
            Some(wire) => {
                entry.insert("color".into(), json!(wire));
            }
            None => diags
                .push(Diag::invalid(format!("{path}.color"), "expected a group color or #RRGGBB")),
        }
    }
    if let Some(raw) = fields.get("icon") {
        match raw.as_str().map(trim_blank).filter(|icon| !icon.is_empty()) {
            Some(icon) => {
                entry.insert("icon".into(), json!(icon));
            }
            None => diags
                .push(Diag::invalid(format!("{path}.icon"), "expected a symbol name or an emoji")),
        }
    }
    if let Some(raw) = fields.get("newWorkspacePlacement")
        && let Some(placement) = placement(raw, &format!("{path}.newWorkspacePlacement"), diags)
    {
        entry.insert("newWorkspacePlacement".into(), json!(placement));
    }
    if let Some(raw) = fields.get("contextMenu") {
        let Some(rows) = raw.as_array() else {
            diags.push(Diag::invalid(
                format!("{path}.contextMenu"),
                "expected a list of {\"action\": ...}",
            ));
            return Value::Object(entry);
        };
        let mut menu = Vec::new();
        for (index, row) in rows.iter().enumerate() {
            let action = row.get("action").and_then(Value::as_str).filter(|a| !a.is_empty());
            let Some(action) = action else {
                diags.push(Diag::invalid(
                    format!("{path}.contextMenu.{index}"),
                    "expected an action",
                ));
                continue;
            };
            let title = row.get("title").and_then(Value::as_str).filter(|t| !t.is_empty());
            menu.push(json!({"action": action, "title": title}));
        }
        entry.insert("contextMenu".into(), Value::Array(menu));
    }
    Value::Object(entry)
}

fn placement(raw: &Value, path: &str, diags: &mut Vec<Diag>) -> Option<&'static str> {
    if let Some(found) = raw.as_str().and_then(|text| PLACEMENTS.iter().find(|p| **p == text)) {
        return Some(found);
    }
    diags.push(Diag::invalid(path, format!("expected one of {}", PLACEMENTS.join(", "))));
    None
}

/// `path` with `~` expanded and no trailing `/`; `None` when empty.
fn expand(path: &str, home: &str) -> Option<String> {
    let mut text = trim_blank(path).to_string();
    if text == "~" {
        text = home.to_string();
    } else if let Some(rest) = text.strip_prefix("~/") {
        text = format!("{home}/{rest}");
    }
    while text.chars().count() > 1 && text.ends_with('/') {
        text.pop();
    }
    (!text.is_empty()).then_some(text)
}

/// The key a new entry for `directory` takes: the folder with the home folder written as `~`.
pub(super) fn key_for(directory: &str, home: &str) -> String {
    let folder = expand(directory, home).unwrap_or_else(|| directory.to_string());
    if folder == home {
        return "~".into();
    }
    match folder.strip_prefix(&format!("{home}/")) {
        Some(rest) => format!("~/{rest}"),
        None => folder,
    }
}

/// A glob (`*`, `?`) matches the whole folder; a plain folder matches itself and every folder inside it.
fn matches(pattern: &str, folder: &str) -> bool {
    if !pattern.contains('*') && !pattern.contains('?') {
        return folder == pattern || pattern == "/" || folder.starts_with(&format!("{pattern}/"));
    }
    let pattern: Vec<char> = pattern.chars().collect();
    let folder: Vec<char> = folder.chars().collect();
    fnmatch(&pattern, &folder)
}

/// POSIX `fnmatch(pattern, string, 0)`: `*`, `?`, `[set]` (`!` or `^` negates, ranges) and `\` escapes;
/// `/` and a leading `.` are ordinary characters.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn fnmatch(pattern: &[char], text: &[char]) -> bool {
    let Some((&first, rest)) = pattern.split_first() else { return text.is_empty() };
    match first {
        '*' => (0..=text.len()).any(|skip| fnmatch(rest, &text[skip..])),
        '?' => !text.is_empty() && fnmatch(rest, &text[1..]),
        '[' => {
            let Some(&c) = text.first() else { return false };
            match class(rest, c) {
                Some((hit, after)) => hit && fnmatch(after, &text[1..]),
                None => c == '[' && fnmatch(rest, &text[1..]),
            }
        }
        '\\' if !rest.is_empty() => {
            text.first() == Some(&rest[0]) && fnmatch(&rest[1..], &text[1..])
        }
        _ => text.first() == Some(&first) && fnmatch(rest, &text[1..]),
    }
}

/// Whether `c` is in the set that starts `pattern` (after the `[`), and what follows the `]`.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn class(pattern: &[char], c: char) -> Option<(bool, &[char])> {
    let mut i = 0;
    let negate = matches!(pattern.first(), Some('!' | '^'));
    if negate {
        i += 1;
    }
    let mut hit = false;
    let mut first = true;
    loop {
        let &item = pattern.get(i)?;
        if item == ']' && !first {
            return Some((hit != negate, &pattern[i + 1..]));
        }
        first = false;
        let low = if item == '\\' {
            i += 1;
            *pattern.get(i)?
        } else {
            item
        };
        if pattern.get(i + 1) == Some(&'-') && pattern.get(i + 2).is_some_and(|c| *c != ']') {
            let high = pattern[i + 2];
            if low <= c && c <= high {
                hit = true;
            }
            i += 3;
        } else {
            if low == c {
                hit = true;
            }
            i += 1;
        }
    }
}

/// The key and entry for a group whose anchor is in `directory`: the longest matching key (ties:
/// the smaller key), `None` when none matches.
fn entry_for(config: &Value, directory: &str, home: &str) -> Option<(String, Value)> {
    let folder = expand(directory, home)?;
    let mut best: Option<(usize, &String, &Value)> = None;
    for (key, entry) in config.get("byCwd")?.as_object()? {
        let Some(pattern) = expand(key, home) else { continue };
        if !matches(&pattern, &folder) {
            continue;
        }
        let length = pattern.chars().count();
        if best.is_none_or(|(len, best_key, _)| length > len || (length == len && key < best_key)) {
            best = Some((length, key, entry));
        }
    }
    best.map(|(_, key, entry)| (key.clone(), entry.clone()))
}
