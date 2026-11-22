//! The human table of `closed list`: one short MEMBERS cell per closed group
//! instead of the full member JSON, which stays in `--json`.

use serde_json::Value;

/// The widest MEMBERS cell, in characters, ellipsis included.
const MAX_CELL: usize = 80;

/// Replaces each row's `members` array with a summary such as
/// `screen https://example.com, workspace build`.
pub(super) fn summarize(rows: &[Value]) -> Value {
    Value::Array(
        rows.iter()
            .map(|row| {
                let mut row = row.clone();
                if let Some(members) = row.get("members").and_then(Value::as_array) {
                    let cell = members.iter().map(member).collect::<Vec<_>>().join(", ");
                    row["members"] = Value::String(truncate(cell));
                }
                row
            })
            .collect(),
    )
}

/// A member's kind and its first name, URL or folder.
fn member(member: &Value) -> String {
    let kind = member.get("kind").and_then(Value::as_str).unwrap_or("member");
    match label(member) {
        Some(label) => format!("{kind} {label}"),
        None => kind.to_owned(),
    }
}

fn label(value: &Value) -> Option<&str> {
    match value {
        Value::Object(object) => ["name", "url", "cwd"]
            .iter()
            .find_map(|key| object.get(*key).and_then(Value::as_str).filter(|s| !s.is_empty()))
            .or_else(|| object.values().find_map(label)),
        Value::Array(values) => values.iter().find_map(label),
        _ => None,
    }
}

fn truncate(cell: String) -> String {
    if cell.chars().count() <= MAX_CELL {
        return cell;
    }
    let mut short = cell.chars().take(MAX_CELL - 1).collect::<String>();
    short.push('…');
    short
}
