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

/// One Show line as the driver writes it.
pub fn show_line(
    cloud: Cloud,
    session: &str,
    reason: Option<&str>,
    machine: Option<&str>,
    at_ms: u64,
) -> Value {
    let mut show = serde_json::Map::new();
    show.insert("cloud".to_owned(), json!(cloud));
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

fn show_of(line: &str) -> Option<(Cloud, Option<String>, Option<u64>)> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    let show = value.get("show")?;
    let cloud: Cloud = serde_json::from_value(show.get("cloud")?.clone()).ok()?;
    let reason = show.get("reason").and_then(Value::as_str).map(str::to_owned);
    Some((cloud, reason, show.get("at").and_then(Value::as_u64)))
}

/// The newest Show in a driver's log text, or None when the log shows nothing (no hybrid start,
/// or its newest Show is `none`). Lines that are not a whole Show (the driver's other lines, a
/// line torn by a write still under way, junk) are skipped, so the Show before them stands. Once
/// a Show says `live` the chat is in Cloud and the answer stays `live`.
pub fn newest(log: &str) -> Option<Start> {
    let mut now: Option<Start> = None;
    for (cloud, reason, at) in log.lines().filter_map(show_of) {
        match &mut now {
            Some(start) if start.cloud == Cloud::Live => break,
            Some(start) if start.cloud == cloud => {
                start.reason = reason;
                start.since_ms = start.since_ms.or(at);
            }
            _ => now = Some(Start { cloud, reason, since_ms: at }),
        }
    }
    now.filter(|start| start.cloud != Cloud::None)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(cloud: Cloud, reason: Option<&str>, at: u64) -> String {
        show_line(cloud, "s1", reason, Some("vm-1"), at).to_string()
    }

    #[test]
    fn newest_show_wins_since_its_state_began() {
        let log = [
            "hybrid start step: gate 3 ms".to_owned(),
            r#"{"plan":"pro"}"#.to_owned(),
            line(Cloud::Booting, None, 100),
            line(Cloud::Ready, None, 200),
            line(Cloud::Ready, None, 250),
            line(Cloud::Moving, None, 300),
        ]
        .join("\n");
        let start = newest(&log).unwrap();
        assert_eq!(start, Start { cloud: Cloud::Moving, reason: None, since_ms: Some(300) });
        let ready = newest(&log.lines().take(5).collect::<Vec<_>>().join("\n")).unwrap();
        assert_eq!(ready.since_ms, Some(200), "a repeated Show keeps when its state began");
        assert_eq!(
            serde_json::to_value(start).unwrap(),
            json!({"cloud": "moving", "sinceMs": 300})
        );
    }

    #[test]
    fn failed_carries_its_reason() {
        let log = [line(Cloud::Booting, None, 1), line(Cloud::Failed, Some("quota"), 2)].join("\n");
        let start = newest(&log).unwrap();
        assert_eq!(start.cloud, Cloud::Failed);
        assert_eq!(start.reason.as_deref(), Some("quota"));
        assert_eq!(
            serde_json::to_value(start).unwrap(),
            json!({"cloud": "failed", "reason": "quota", "sinceMs": 2})
        );
    }

    #[test]
    fn no_show_is_no_start() {
        assert_eq!(newest(""), None);
        assert_eq!(newest("hybrid start step: gate 3 ms\n{\"plan\":null}\n"), None);
        assert_eq!(newest(&line(Cloud::None, None, 1)), None);
    }

    #[test]
    fn torn_or_junk_last_line_leaves_the_show_before() {
        let ready = line(Cloud::Ready, None, 5);
        let moving = line(Cloud::Moving, None, 6);
        let torn = format!("{ready}\n{}", &moving[..moving.len() / 2]);
        assert_eq!(newest(&torn).unwrap().cloud, Cloud::Ready);
        let junk = format!("{ready}\n\u{0}garbage{{\n");
        assert_eq!(newest(&junk).unwrap().cloud, Cloud::Ready);
        let wrong = format!("{ready}\n{{\"show\":{{\"cloud\":\"sideways\"}}}}\n");
        assert_eq!(newest(&wrong).unwrap().cloud, Cloud::Ready);
    }

    #[test]
    fn live_stays_live() {
        let log = [line(Cloud::Live, None, 9), line(Cloud::Failed, Some("late"), 10)].join("\n");
        assert_eq!(
            newest(&log).unwrap(),
            Start { cloud: Cloud::Live, reason: None, since_ms: Some(9) }
        );
    }

    #[test]
    fn paths_sit_beside_the_sessions_folder() {
        let sessions = Path::new("/state/cmux-tui/sessions");
        assert_eq!(
            log_file(sessions, "a/b c"),
            Path::new("/state/cmux-tui/hybrid-start/a-b-c.log")
        );
        assert_eq!(show_file(sessions, "s1"), Path::new("/state/cmux-tui/hybrid-start/s1.show"));
    }
}
