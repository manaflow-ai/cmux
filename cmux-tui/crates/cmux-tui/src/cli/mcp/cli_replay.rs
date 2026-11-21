//! Section 7 of the MCP ergonomics design: repeat a successful read by hand.
//! The first slice is machine metadata, behind the existing default-off Labs switch.

use std::path::Path;

use serde_json::{Map, Value};

use super::super::GlobalArgs;

pub(super) fn machine_get(
    path: &Path,
    global: &GlobalArgs,
    arguments: &Map<String, Value>,
) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let config: Value = serde_json::from_str(&super::config::strip_jsonc(&text)).ok()?;
    if config.pointer("/labs/previewFeatures").and_then(Value::as_bool) != Some(true)
        || global.all_sessions
    {
        return None;
    }
    let machine = arguments.get("machine")?.as_str()?;
    // A positional selector beginning with '-' would be parsed as a CLI option.
    if machine.starts_with('-') {
        return None;
    }
    let mut words = vec!["cmux".to_owned(), "--json".to_owned()];
    let socket = match global.socket.as_deref() {
        Some(path) => Some(path.to_str()?),
        None => None,
    };
    let app_socket = match global.app_socket.as_deref() {
        Some(path) => Some(path.to_str()?),
        None => None,
    };
    for (flag, value) in [
        ("--socket", socket),
        ("--app-socket", app_socket),
        (
            "--session",
            arguments.get("session").and_then(Value::as_str).or(global.session.as_deref()),
        ),
        ("--machine", global.machine.as_deref()),
    ] {
        if let Some(value) = value {
            words.extend([flag.to_owned(), value.to_owned()]);
        }
    }
    words.extend(["machine".to_owned(), machine.to_owned(), "show".to_owned()]);
    if arguments.get("catalog").and_then(Value::as_bool) == Some(true) {
        words.push("--catalog".to_owned());
    }
    Some(words.iter().map(|word| quote(word)).collect::<Vec<_>>().join(" "))
}

fn quote(word: &str) -> String {
    if !word.is_empty() && word.bytes().all(|c| c.is_ascii_alphanumeric() || b"_./:-".contains(&c))
    {
        word.to_owned()
    } else {
        format!("'{}'", word.replace('\'', "'\"'\"'"))
    }
}
