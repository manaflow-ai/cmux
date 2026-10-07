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
//! is rotated once at [`MAX_LOG_BYTES`] (one previous file is kept).

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
    let cause = if signals.iter().any(|line| line.get("signal").is_some()) {
        "host ended after recorded signals (the host survives these; a later uncatchable end followed)"
    } else {
        "no catchable signal recorded: SIGKILL, a crash, or memory pressure"
    };
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
