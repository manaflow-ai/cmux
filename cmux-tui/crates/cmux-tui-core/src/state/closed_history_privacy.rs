//! What closed history never stores (plans/cmux-next/reopen-closed.md 3.0,
//! 7.5 and 7.17): URL query keys that look like secrets, and the windows of
//! incognito (ephemeral) workspaces. Content of an ephemeral workspace is
//! already left out where groups are captured (`closed_history_store`).

use rusqlite::Connection;
use serde_json::Value;

/// Parts of a query key (lowercase, `-` and `.` read as `_`) that mark it as
/// a secret: tokens, OAuth codes, signatures, keys, passwords, sessions.
const SECRET_PARTS: [&str; 10] = [
    "token",
    "secret",
    "password",
    "passwd",
    "signature",
    "credential",
    "auth",
    "session",
    "cookie",
    "apikey",
];

/// Whole query keys that are secrets on their own.
const SECRET_KEYS: [&str; 5] = ["code", "sig", "key", "pwd", "jwt"];

fn is_secret_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase().replace(['-', '.'], "_");
    SECRET_KEYS.contains(&key.as_str())
        || key.ends_with("_key")
        || SECRET_PARTS.iter().any(|part| key.contains(part))
}

/// `url` without its secret query keys. Anything that does not parse as a
/// URL with a query is returned as is.
pub(super) fn strip_url(url: &str) -> String {
    let Ok(mut parsed) = url::Url::parse(url) else { return url.to_string() };
    if parsed.query().is_none() {
        return url.to_string();
    }
    let kept = parsed
        .query_pairs()
        .filter(|(key, _)| !is_secret_key(key))
        .map(|(key, value)| (key.into_owned(), value.into_owned()))
        .collect::<Vec<_>>();
    if kept.len() == parsed.query_pairs().count() {
        return url.to_string();
    }
    if kept.is_empty() {
        parsed.set_query(None);
    } else {
        parsed.query_pairs_mut().clear().extend_pairs(kept);
    }
    parsed.to_string()
}

/// A frontend browser's opaque session history (a JSON object) with every
/// `url` string in it stripped. History with nothing to strip is kept byte
/// for byte; history that does not parse is dropped.
pub(super) fn strip_history(history: &str) -> Value {
    fn walk(value: &mut Value) -> bool {
        match value {
            Value::Object(map) => {
                let mut changed = false;
                for (key, item) in map.iter_mut() {
                    match item {
                        Value::String(text) if key == "url" => {
                            let stripped = strip_url(text);
                            if stripped != *text {
                                *text = stripped;
                                changed = true;
                            }
                        }
                        _ => changed |= walk(item),
                    }
                }
                changed
            }
            Value::Array(items) => {
                items.iter_mut().fold(false, |changed, item| walk(item) | changed)
            }
            _ => false,
        }
    }
    let Ok(mut parsed) = serde_json::from_str::<Value>(history) else { return Value::Null };
    if walk(&mut parsed) {
        Value::String(parsed.to_string())
    } else {
        Value::String(history.to_string())
    }
}

/// Whether a window record that lists `keys` is an incognito window: it
/// lists workspaces, and none of them is a live workspace that is not
/// ephemeral. A window that lists nothing is not incognito.
pub(super) fn is_private_window(connection: &Connection, keys: &[String]) -> anyhow::Result<bool> {
    if keys.is_empty() {
        return Ok(false);
    }
    let keys_json = serde_json::to_string(keys)?;
    let normal: bool = connection.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM resource_workspaces AS rw
           WHERE rw.workspace_key IN (SELECT value FROM json_each(?1))
             AND rw.deleted_revision IS NULL
             AND NOT EXISTS (SELECT 1 FROM workspace_state AS ws
                             WHERE ws.workspace_id = rw.public_id AND ws.ephemeral != 0))",
        [keys_json],
        |row| row.get(0),
    )?;
    Ok(!normal)
}
