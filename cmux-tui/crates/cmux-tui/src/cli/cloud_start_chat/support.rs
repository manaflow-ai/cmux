//! Small helpers every part of the start shares.

use serde_json::Value;

/// `value[key]` without indexing: `Null` when absent.
pub(super) fn at<'a>(value: &'a Value, key: &str) -> &'a Value {
    const NULL: &Value = &Value::Null;
    value.get(key).unwrap_or(NULL)
}

/// `list` as owned words, for a step's arguments.
pub(super) fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

/// The `@@name` sections a step's script printed: `@@exit 0` is the section `exit` with `0`.
pub(in crate::cli) fn sections(stdout: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    let mut current: Option<String> = None;
    for line in stdout.lines() {
        if let Some(header) = line.strip_prefix("@@") {
            let (name, rest) = header.split_once(' ').unwrap_or((header, ""));
            out.insert(name.to_owned(), rest.to_owned());
            current = Some(name.to_owned());
            continue;
        }
        if let Some(name) = &current {
            let text: &mut String = out.entry(name.clone()).or_default();
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(line);
        }
    }
    out
}

/// The newest turn `acp history --json` lists.
#[derive(Debug, PartialEq)]
pub(super) struct Turn {
    pub seq: u64,
    pub ended: bool,
    pub status: String,
    pub value: Value,
}

impl Turn {
    /// A turn that ended without its reply: failed, cancelled or of unknown outcome.
    pub(super) fn failed(&self) -> bool {
        matches!(self.status.as_str(), "failed" | "error" | "cancelled" | "outcome_unknown")
            || self.value.get("error").is_some_and(|error| !error.is_null())
    }
}

pub(super) fn last_turn(history: Option<&String>) -> Option<Turn> {
    let value: Value = serde_json::from_str(history?.trim()).ok()?;
    let turn = at(&value, "turns").as_array()?.last()?.clone();
    Some(Turn {
        seq: at(&turn, "seq").as_u64().unwrap_or(0),
        ended: turn.get("endedAt").is_some_and(|at| !at.is_null()),
        status: at(&turn, "status").as_str().unwrap_or("completed").to_owned(),
        value: turn,
    })
}

/// The newest reply `acp last --json` printed (`{"sessionId", "replies": [...]}`).
pub(super) fn reply(last: Option<&String>) -> Option<String> {
    let value: Value = serde_json::from_str(last?.trim()).ok()?;
    at(&value, "replies").as_array()?.last()?.as_str().map(str::to_owned)
}

/// The folder `session` runs in on its machine, from `acp ls --json --fields sessionId,cwd`
/// (`{"sessions": [...]}`, or the rows alone): a folderless chat's is the fresh folder the machine
/// made for it (`~/chats/<chat>`, acpmux `remote_guard.rs` `peer_scratch`). None when unread.
pub(super) fn session_cwd(listed: Option<&String>, session: &str) -> Option<String> {
    let value: Value = serde_json::from_str(listed?.trim()).ok()?;
    let rows = value.get("sessions").unwrap_or(&value).as_array()?;
    rows.iter()
        .find(|row| ["sessionId", "id"].iter().any(|key| at(row, key).as_str() == Some(session)))
        .and_then(|row| at(row, "cwd").as_str())
        .filter(|cwd| cwd.starts_with('/'))
        .map(str::to_owned)
}

/// Where a start's chat runs: `copied` (`--from-folder`: a copy of a folder on this Mac), `given`
/// (`--cwd`: a folder already on the machine), or `fresh` (neither: a folder of its own the machine
/// makes for it, empty at the start; a repository comes later with `cmux chat cd`). A folderless
/// start is a first-class one (Leo, 2026-11-09: "this no folder selected should be, like, good as
/// well").
pub(super) fn folder_kind(cwd: Option<&str>, from_folder: Option<&str>) -> &'static str {
    match (cwd, from_folder) {
        (_, Some(_)) => "copied",
        (Some(_), None) => "given",
        (None, None) => "fresh",
    }
}
