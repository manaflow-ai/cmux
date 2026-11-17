//! The last agent chat this terminal started or sent to, so the next command to it needs no
//! session id: `cmux chat send 'next'`, `cmux chat wait last`, `cmux chat read last` (Leo,
//! 2026-11-10: "We need to keep cleaning up the cli commands so they're nice to type and
//! intuitive and ergonomic and go with best practices"). Before, every follow-up took the 36
//! character session id copied from the start's answer: the thing you just made is the default.
//!
//! The record is a small file in the state folder (`$XDG_STATE_HOME/cmux/last-chat.json`, else
//! `~/.local/state/cmux/`), one entry per cmux terminal (`CMUX_TUI_TERMINAL_ID`,
//! `CMUX_SURFACE_ID`) and the newest overall: this terminal's, else the newest. A chat on a Cloud
//! VM keeps its VM, so its follow-up goes there without the app's lookup. Writing it never fails
//! a command: a folder that cannot be written means only that the next command needs the id.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

/// The word that names the last chat where a SESSION goes (`cmux chat wait last`).
pub(super) const LAST: &str = "last";

/// Terminals remembered at most; the oldest go first.
const KEEP: usize = 64;

/// The last chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Last {
    pub session: String,
    /// The Cloud VM's machine id when the chat runs on one.
    pub vm: Option<String>,
}

fn path() -> Option<PathBuf> {
    if let Some(file) = std::env::var_os("CMUX_LAST_CHAT_FILE").filter(|file| !file.is_empty()) {
        return Some(PathBuf::from(file));
    }
    let state = std::env::var_os("XDG_STATE_HOME")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .filter(|home| !home.is_empty())
                .map(|home| PathBuf::from(home).join(".local/state"))
        })?;
    Some(state.join("cmux/last-chat.json"))
}

/// This terminal's key: its cmux terminal id, else `-` (any shell outside cmux).
fn terminal() -> String {
    ["CMUX_TUI_TERMINAL_ID", "CMUX_SURFACE_ID"]
        .iter()
        .find_map(|name| std::env::var(name).ok().filter(|id| !id.is_empty()))
        .unwrap_or_else(|| "-".to_owned())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

/// Records `session` (on Cloud VM `vm`, if any) as this terminal's last chat.
pub(super) fn remember(session: &str, vm: Option<&str>) {
    // Unit tests drive the starts with fake runners: they never write a person's state.
    if session.is_empty() || (cfg!(test) && std::env::var_os("CMUX_LAST_CHAT_FILE").is_none()) {
        return;
    }
    let Some(path) = path() else { return };
    let mut book = read(&path);
    book.insert(terminal(), json!({"session": session, "vm": vm, "at": now_ms()}));
    let book = pruned(book, KEEP);
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let temp = path.with_extension(format!("json.{}", std::process::id()));
    if std::fs::write(&temp, Value::Object(book).to_string()).is_ok() {
        let _ = std::fs::rename(&temp, &path);
    } else {
        let _ = std::fs::remove_file(&temp);
    }
}

/// This terminal's last chat, else the newest any terminal recorded.
pub(super) fn recall() -> Option<Last> {
    pick(&read(&path()?), &terminal())
}

fn read(path: &std::path::Path) -> Map<String, Value> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default()
}

fn entry(value: &Value) -> Option<Last> {
    let session = value.get("session")?.as_str()?.to_owned();
    let vm = value.get("vm").and_then(Value::as_str).map(str::to_owned);
    Some(Last { session, vm })
}

fn at(value: &Value) -> u64 {
    value.get("at").and_then(Value::as_u64).unwrap_or(0)
}

/// `terminal`'s entry, else the newest.
pub(super) fn pick(book: &Map<String, Value>, terminal: &str) -> Option<Last> {
    if let Some(found) = book.get(terminal).and_then(entry) {
        return Some(found);
    }
    book.values().max_by_key(|value| at(value)).and_then(entry)
}

/// `book` with only its `keep` newest entries.
pub(super) fn pruned(book: Map<String, Value>, keep: usize) -> Map<String, Value> {
    let mut entries: Vec<(String, Value)> = book.into_iter().collect();
    entries.sort_by_key(|(_, value)| std::cmp::Reverse(at(value)));
    entries.truncate(keep);
    entries.into_iter().collect()
}

/// The refusal when no chat was recorded: name it, or start one.
pub(super) fn none_yet() -> Value {
    json!({
        "code": "chat.no_last_chat",
        "message": "no chat started or sent to from this terminal yet; name it with its SESSION \
                    id (`cmux chats list`), or start one: cmux chat 'PROMPT'",
        "details": {"next": "cmux chats list"},
        "retryable": false,
    })
}

#[cfg(test)]
mod tests {
    use serde_json::{Map, Value, json};

    use super::{Last, pick, pruned};

    fn book(entries: &[(&str, &str, Option<&str>, u64)]) -> Map<String, Value> {
        entries
            .iter()
            .map(|(terminal, session, vm, at)| {
                ((*terminal).to_owned(), json!({"session": session, "vm": vm, "at": at}))
            })
            .collect()
    }

    #[test]
    fn this_terminals_chat_else_the_newest() {
        let book = book(&[("term_1", "s-1", None, 10), ("term_2", "s-2", Some("vm_a"), 20)]);
        assert_eq!(pick(&book, "term_1"), Some(Last { session: "s-1".into(), vm: None }));
        assert_eq!(
            pick(&book, "term_9"),
            Some(Last { session: "s-2".into(), vm: Some("vm_a".into()) })
        );
        assert_eq!(pick(&Map::new(), "term_1"), None);
    }

    #[test]
    fn only_the_newest_entries_stay() {
        let book = book(&[("a", "1", None, 1), ("b", "2", None, 3), ("c", "3", None, 2)]);
        let kept = pruned(book, 2);
        assert_eq!(kept.keys().cloned().collect::<Vec<_>>(), ["b", "c"]);
    }
}
