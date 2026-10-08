//! The local log of lost terminal hosts (cx-6so.49, L0).
//!
//! A terminal whose host ended without an exit record is a host loss
//! ([`TerminalEnd::HostLost`]). The owner appends one JSON line per loss to
//! `terminal-losses.jsonl` in the session's state directory (the parent of
//! the terminal-host record directory), with the typed end and every signal
//! the host recorded before it ended (`<terminal-id>.signals`, written by
//! the host's signal guard). A loss with no recorded signal was caused by
//! something the host could not observe: `SIGKILL`, a crash, or memory
//! pressure. The file is local diagnostics only; nothing reads it back. It
//! is rotated once at [`MAX_LOG_BYTES`] (one previous file is kept). A dead
//! host replaced on its still-running shell (PTY custody) is logged as an
//! `"event":"host_replaced"` line instead; it is not a loss. A terminal that
//! got a new shell after a loss (L2 respawn) adds a
//! `"event":"terminal_respawned"` line after its loss line.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::terminal_end::TerminalEnd;

/// File name of the loss log in the session state directory.
pub(crate) const LOSS_LOG_FILE: &str = "terminal-losses.jsonl";
const MAX_LOG_BYTES: u64 = 1024 * 1024;
const MAX_SIGNAL_LINES: usize = 64;

/// The host's signal breadcrumbs for the discovery record at `record_path`.
pub(crate) fn signals_path(record_path: &Path) -> PathBuf {
    record_path.with_extension("signals")
}

/// Remove a host's signal breadcrumbs (its terminal ended and was recorded).
pub(crate) fn remove_signals(record_path: &Path) {
    let _ = fs::remove_file(signals_path(record_path));
}

fn read_signals(record_path: &Path, incarnation: Option<&str>) -> Vec<serde_json::Value> {
    let Ok(text) = fs::read_to_string(signals_path(record_path)) else { return Vec::new() };
    let mut signals = text
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|line| {
            incarnation.is_none_or(|incarnation| {
                line.get("incarnation").and_then(serde_json::Value::as_str) == Some(incarnation)
            })
        })
        .collect::<Vec<_>>();
    if signals.len() > MAX_SIGNAL_LINES {
        signals.drain(..signals.len() - MAX_SIGNAL_LINES);
    }
    signals
}

/// Why a host ended, from the signals it recorded.
fn end_cause(signals: &[serde_json::Value]) -> &'static str {
    if signals.iter().any(|line| line.get("signal").is_some()) {
        "host ended after recorded signals (the host survives these; a later uncatchable end followed)"
    } else {
        "no catchable signal recorded: SIGKILL, a crash, or memory pressure"
    }
}

/// The loss line for a host-lost terminal; `None` for any other end.
pub(crate) fn loss_line(
    record_path: &Path,
    terminal_id: &str,
    incarnation: Option<&str>,
    end: &TerminalEnd,
    at_ms: u128,
) -> Option<serde_json::Value> {
    if !matches!(end, TerminalEnd::HostLost(_)) {
        return None;
    }
    let signals = read_signals(record_path, incarnation);
    let cause = end_cause(&signals);
    Some(serde_json::json!({
        "at_ms": at_ms,
        "terminal_id": terminal_id,
        "incarnation": incarnation,
        "end": end.wire_json(),
        "cause": cause,
        "signals": signals,
    }))
}

/// Append the loss of `terminal_id` to the session's loss log and remove the
/// host's breadcrumbs. Best effort: a failure never affects the exit commit.
pub(crate) fn record_host_loss(
    record_path: &Path,
    terminal_id: &str,
    incarnation: Option<&str>,
    end: &TerminalEnd,
) {
    let at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or_default();
    let Some(line) = loss_line(record_path, terminal_id, incarnation, end, at_ms) else {
        return;
    };
    eprintln!("cmux-tui: terminal {terminal_id} lost its host: {line}");
    if let Some(log) =
        record_path.parent().and_then(Path::parent).map(|dir| dir.join(LOSS_LOG_FILE))
    {
        append_rotating(&log, &line);
    }
    remove_signals(record_path);
}

/// Append the replacement of a dead host by a new host on the same running
/// shell (cx-6so.49 L1.2) and remove the dead host's breadcrumbs. A
/// replacement is not a loss: the terminal keeps its incarnation and shell.
pub(crate) fn record_host_replaced(
    record_path: &Path,
    terminal_id: &str,
    incarnation: &str,
    old_host_pid: u32,
    new_host_pid: u32,
) {
    let at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or_default();
    let signals = read_signals(record_path, Some(incarnation));
    let cause = end_cause(&signals);
    let line = serde_json::json!({
        "at_ms": at_ms,
        "event": "host_replaced",
        "terminal_id": terminal_id,
        "incarnation": incarnation,
        "old_host_pid": old_host_pid,
        "new_host_pid": new_host_pid,
        "cause": cause,
        "signals": signals,
    });
    eprintln!("cmux-tui: terminal {terminal_id} got a replacement host: {line}");
    if let Some(log) =
        record_path.parent().and_then(Path::parent).map(|dir| dir.join(LOSS_LOG_FILE))
    {
        append_rotating(&log, &line);
    }
    remove_signals(record_path);
}

/// What a respawned terminal's new shell had pre-filled on its input line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Prefilled {
    /// An agent resume command (`claude --resume`, `codex resume`).
    Harness,
    /// The terminal's earlier command line.
    Command,
    None,
}

impl Prefilled {
    fn as_str(self) -> &'static str {
        match self {
            Self::Harness => "harness",
            Self::Command => "command",
            Self::None => "none",
        }
    }
}

/// The respawn line for `terminal_id` (cx-6so.49 L2).
pub(crate) fn respawn_line(
    terminal_id: &str,
    (old_incarnation, new_incarnation): (&str, &str),
    cause: &str,
    prefilled: Prefilled,
    at_ms: u128,
) -> serde_json::Value {
    serde_json::json!({
        "at_ms": at_ms,
        "event": "terminal_respawned",
        "terminal_id": terminal_id,
        "old_incarnation": old_incarnation,
        "new_incarnation": new_incarnation,
        "cause": cause,
        "prefilled": prefilled.as_str(),
    })
}

/// Append that terminal `terminal_id`, whose shell was lost with its host
/// (`cause`, the `host_lost` reason), runs a new shell under the same id
/// (cx-6so.49 L2). `root` is the terminal-host record directory.
pub(crate) fn record_terminal_respawned(
    root: &Path,
    terminal_id: &str,
    incarnations: (&str, &str),
    cause: &str,
    prefilled: Prefilled,
) {
    let at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or_default();
    let line = respawn_line(terminal_id, incarnations, cause, prefilled, at_ms);
    eprintln!("cmux-tui: terminal {terminal_id} respawned: {line}");
    if let Some(log) = root.parent().map(|dir| dir.join(LOSS_LOG_FILE)) {
        append_rotating(&log, &line);
    }
}

fn append_rotating(log: &Path, line: &serde_json::Value) {
    if fs::metadata(log).is_ok_and(|metadata| metadata.len() >= MAX_LOG_BYTES) {
        let _ = fs::rename(log, log.with_extension("jsonl.1"));
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    if let Ok(mut file) = options.open(log) {
        let _ = writeln!(file, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cmux-loss-log-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(dir.join("terminal-hosts-x")).unwrap();
        dir
    }

    #[test]
    fn host_loss_is_logged_with_its_recorded_signals_and_breadcrumbs_are_removed() {
        let root = temp_root("signals");
        let record = root.join("terminal-hosts-x").join("abc.json");
        fs::write(
            signals_path(&record),
            concat!(
                r#"{"terminal_id":"abc","incarnation":"i1","signal":15,"sender_pid":42,"at_ms":1,"action":"ignored"}"#,
                "\n",
                r#"{"terminal_id":"abc","incarnation":"old","signal":1,"sender_pid":7,"at_ms":0,"action":"ignored"}"#,
                "\n",
            ),
        )
        .unwrap();
        let end = TerminalEnd::host_lost("terminal host ended without a durable exit sidecar");
        record_host_loss(&record, "abc", Some("i1"), &end);

        let text = fs::read_to_string(root.join(LOSS_LOG_FILE)).unwrap();
        let line: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        assert_eq!(line["terminal_id"], "abc");
        assert_eq!(line["end"]["kind"], "host_lost");
        assert_eq!(line["end"]["reason"], "died_without_exit_status");
        assert_eq!(line["signals"].as_array().unwrap().len(), 1, "{line}");
        assert_eq!(line["signals"][0]["sender_pid"], 42);
        assert!(!signals_path(&record).exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_host_replacement_is_logged_as_its_own_event_and_removes_breadcrumbs() {
        let root = temp_root("replaced");
        let record = root.join("terminal-hosts-x").join("abc.json");
        fs::write(signals_path(&record), "").unwrap();
        record_host_replaced(&record, "abc", "i1", 10, 20);
        let text = fs::read_to_string(root.join(LOSS_LOG_FILE)).unwrap();
        let line: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        assert_eq!(line["event"], "host_replaced");
        assert_eq!(
            (line["old_host_pid"].as_u64(), line["new_host_pid"].as_u64()),
            (Some(10), Some(20))
        );
        assert!(line.get("end").is_none(), "a replacement is not an end: {line}");
        assert!(line["cause"].as_str().unwrap().contains("SIGKILL"), "{line}");
        assert!(!signals_path(&record).exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_respawn_is_logged_as_its_own_event() {
        let root = temp_root("respawned");
        let hosts = root.join("terminal-hosts-x");
        record_terminal_respawned(
            &hosts,
            "abc",
            ("i1", "i2"),
            "dead_before_adoption",
            Prefilled::Harness,
        );
        let text = fs::read_to_string(root.join(LOSS_LOG_FILE)).unwrap();
        let line: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        assert_eq!(line["event"], "terminal_respawned");
        assert_eq!(
            (line["old_incarnation"].as_str(), line["new_incarnation"].as_str()),
            (Some("i1"), Some("i2"))
        );
        assert_eq!(line["cause"], "dead_before_adoption");
        assert_eq!(line["prefilled"], "harness");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_loss_without_signals_names_an_uncatchable_end_and_process_ends_are_not_logged() {
        let root = temp_root("nosignals");
        let record = root.join("terminal-hosts-x").join("abc.json");
        let exit = crate::terminal_host_protocol::TerminalExit::now(
            crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        );
        record_host_loss(&record, "abc", Some("i1"), &TerminalEnd::ProcessEnded(exit));
        assert!(!root.join(LOSS_LOG_FILE).exists());

        record_host_loss(
            &record,
            "abc",
            Some("i1"),
            &TerminalEnd::host_lost("missing-host-record"),
        );
        let text = fs::read_to_string(root.join(LOSS_LOG_FILE)).unwrap();
        let line: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        assert!(line["cause"].as_str().unwrap().contains("SIGKILL"), "{line}");
        assert_eq!(line["end"]["reason"], "missing_record");
        let _ = fs::remove_dir_all(root);
    }
}
