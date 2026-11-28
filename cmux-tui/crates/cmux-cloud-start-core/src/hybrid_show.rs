//! What a hybrid start shows now ([`crate::hybrid`]'s `Effect::Show`), read back from its
//! driver's log for the chat header's `place.start` (`{"cloud", "reason"?, "sinceMs"?}`).
//!
//! The driver (`cmux cloud hybrid-drive`) appends one JSON line per Show to
//! `<cmux-tui state root>/hybrid-start/<session>.log` (`{"show": {"cloud", "session", "reason"?,
//! "machine"?, "at"}}`, `at` in Unix milliseconds) among its other lines, then replaces
//! `<session>.show` with the same line by a rename. The rename is the change signal: it changes
//! the folder, so a watch on the folder (the app's `FolderChanges`) wakes once per Show, and the
//! app reads [`newest`] again. Nothing polls.
//!
//! Pure: paths are computed from the state folder the caller names, the log's text is passed in.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Value, json};

use crate::hybrid::Cloud;

/// The driver's folder under the cmux-tui state root.
pub const FOLDER: &str = "hybrid-start";

/// The newest Show of a session, as `place.start` carries it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Start {
    pub cloud: Cloud,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// When the start entered `cloud` (Unix milliseconds): the first Show of the newest run of
    /// Shows with this `cloud`. None for lines written before the driver stamped them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub since_ms: Option<u64>,
    /// How ready the machine is, 0 to 100 ([`crate::hybrid_tools::readiness`]): the line's own
    /// when it carries one, else its stage's. None when the start failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub readiness: Option<u8>,
}

/// The driver's folder for the cmux-tui sessions folder `sessions` (`workspace_state_dir`, the
/// app's `CMUX_TUI_STATE_DIR`): beside it, under the state root.
pub fn folder(sessions: &Path) -> PathBuf {
    sessions.parent().unwrap_or(sessions).join(FOLDER)
}

/// A session id as a file name: anything but ASCII letters, digits, `-`, `_` and `.` is `-`.
pub fn file_stem(session: &str) -> String {
    session
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' })
        .collect()
}

/// The driver's log: its `Log` lines and `Show` states, one per line.
pub fn log_file(sessions: &Path, session: &str) -> PathBuf {
    folder(sessions).join(format!("{}.log", file_stem(session)))
}

/// The session's newest Show alone, replaced by a rename on each Show (the change signal).
pub fn show_file(sessions: &Path, session: &str) -> PathBuf {
    folder(sessions).join(format!("{}.show", file_stem(session)))
}

/// One Show line as the driver writes it, with its readiness (0 to 100) when the start has one.
pub fn show_line(
    cloud: Cloud,
    session: &str,
    reason: Option<&str>,
    machine: Option<&str>,
    at_ms: u64,
) -> Value {
    let mut show = serde_json::Map::new();
    show.insert("cloud".to_owned(), json!(cloud));
    if let Some(readiness) = crate::hybrid_tools::readiness(cloud, &[]) {
        show.insert("readiness".to_owned(), json!(readiness));
    }
    show.insert("session".to_owned(), json!(session));
    show.insert("at".to_owned(), json!(at_ms));
    if let Some(reason) = reason {
        show.insert("reason".to_owned(), json!(reason));
    }
    if let Some(machine) = machine {
        show.insert("machine".to_owned(), json!(machine));
    }
    json!({ "show": show })
}

type Shown = (Cloud, Option<String>, Option<u64>, Option<u8>);

fn show_of(line: &str) -> Option<Shown> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    let show = value.get("show")?;
    let cloud: Cloud = serde_json::from_value(show.get("cloud")?.clone()).ok()?;
    let reason = show.get("reason").and_then(Value::as_str).map(str::to_owned);
    // A line from before readiness was written: its stage's.
    let readiness = crate::hybrid_tools::readiness(cloud, &[]).map(|stage| {
        show.get("readiness")
            .and_then(Value::as_u64)
            .and_then(|value| u8::try_from(value.min(100)).ok())
            .unwrap_or(stage)
    });
    Some((cloud, reason, show.get("at").and_then(Value::as_u64), readiness))
}

/// The newest Show in a driver's log text, or None when the log shows nothing (no hybrid start,
/// or its newest Show is `none`). Lines that are not a whole Show (the driver's other lines, a
/// line torn by a write still under way, junk) are skipped, so the Show before them stands. Once
/// a Show says `live` the chat is in Cloud and the answer stays `live`. Readiness never goes
/// down while the start boots: the highest seen stands until the start fails.
pub fn newest(log: &str) -> Option<Start> {
    let mut now: Option<Start> = None;
    for (cloud, reason, at, readiness) in log.lines().filter_map(show_of) {
        let before = now.as_ref().and_then(|start| start.readiness);
        let readiness = readiness.map(|ready| before.map_or(ready, |before| ready.max(before)));
        match &mut now {
            Some(start) if start.cloud == Cloud::Live => break,
            Some(start) if start.cloud == cloud => {
                start.reason = reason;
                start.since_ms = start.since_ms.or(at);
                start.readiness = readiness;
            }
            _ => now = Some(Start { cloud, reason, since_ms: at, readiness }),
        }
    }
    now.filter(|start| start.cloud != Cloud::None)
}

#[cfg(test)]
#[path = "hybrid_show_tests.rs"]
mod tests;
