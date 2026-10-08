//! Why a terminal host was lost (cx-0tgl LA), from the evidence its host
//! left: the signals it recorded (with each sender) and its last panic.
//!
//! Two forms: the cause TEXT for `terminal-losses.jsonl` (every recorded
//! sender, the panic message and location), and a small structured
//! SUMMARY for the tab's `end.cause` that frontends render with their own
//! localized words: the first recorded signal, its sender's name and PID,
//! and whether the host had panicked. The summary carries no panic message,
//! path or backtrace.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// The host's crash sidecar (its last panic, written by the host's panic
/// hook) for the discovery record at `record_path`.
pub(crate) fn crash_path(record_path: &Path) -> PathBuf {
    record_path.with_extension("crash")
}

/// The host's last panic, only when it belongs to `incarnation`.
pub(crate) fn read_crash(record_path: &Path, incarnation: Option<&str>) -> Option<Value> {
    let incarnation = incarnation?;
    let text = fs::read_to_string(crash_path(record_path)).ok()?;
    let crash = serde_json::from_str::<Value>(&text).ok()?;
    (crash.get("incarnation").and_then(Value::as_str) == Some(incarnation)).then_some(crash)
}

/// The conventional name of a signal number.
pub(crate) fn signal_name(signal: i64) -> String {
    let known = [
        (libc::SIGHUP, "SIGHUP"),
        (libc::SIGINT, "SIGINT"),
        (libc::SIGQUIT, "SIGQUIT"),
        (libc::SIGTERM, "SIGTERM"),
        (libc::SIGUSR1, "SIGUSR1"),
        (libc::SIGUSR2, "SIGUSR2"),
        (libc::SIGALRM, "SIGALRM"),
        (libc::SIGTSTP, "SIGTSTP"),
        (libc::SIGXCPU, "SIGXCPU"),
        (libc::SIGXFSZ, "SIGXFSZ"),
    ];
    known
        .iter()
        .find(|(number, _)| i64::from(*number) == signal)
        .map_or_else(|| format!("signal {signal}"), |(_, name)| (*name).to_string())
}

fn sender_name(line: &Value) -> Option<&str> {
    line.get("sender")?.get("name")?.as_str()
}

/// "SIGTERM from pid 84954 (bash, parent 1 launchd)" for one recorded signal.
fn describe_signal(line: &Value) -> Option<String> {
    let signal = signal_name(line.get("signal")?.as_i64()?);
    let pid = line.get("sender_pid").and_then(Value::as_i64).unwrap_or(0);
    let sender = line.get("sender").filter(|sender| !sender.is_null());
    let who = match sender {
        Some(sender) if sender.get("reused").is_some() => "exited; pid reused".to_string(),
        Some(sender) => {
            let name = sender_name(line).unwrap_or("?");
            match sender.get("ppid").and_then(Value::as_u64) {
                Some(ppid) => {
                    let parent = sender.get("parent_name").and_then(Value::as_str);
                    format!("{name}, parent {ppid} {}", parent.unwrap_or("gone"))
                }
                None => name.to_string(),
            }
        }
        None => "exited".to_string(),
    };
    let uid = line.get("sender_uid").and_then(Value::as_u64);
    let uid = uid.map(|uid| format!(", uid {uid}")).unwrap_or_default();
    Some(format!("{signal} from pid {pid} ({who}{uid})"))
}

/// The cause text for the loss log.
pub(crate) fn cause_text(signals: &[Value], crash: Option<&Value>) -> String {
    let senders = signals.iter().filter_map(describe_signal).collect::<Vec<_>>();
    let mut cause = if senders.is_empty() {
        "no catchable signal recorded: SIGKILL, a crash, or memory pressure".to_string()
    } else {
        format!(
            "{}; the host survives these, then an uncatchable end followed (SIGKILL, a crash, \
             or memory pressure)",
            senders.join("; ")
        )
    };
    if let Some(crash) = crash {
        let thread = crash.get("thread").and_then(Value::as_str).unwrap_or("?");
        let message = crash.get("message").and_then(Value::as_str).unwrap_or("");
        let location = crash.get("location").and_then(Value::as_str).unwrap_or("?");
        cause.push_str(&format!(
            "; the host had panicked in thread {thread}: {message} (at {location})"
        ));
    }
    cause
}

/// The structured cause for the tab's `end.cause`, or `None` when the host
/// left no evidence (no signal, no panic).
pub(crate) fn cause_summary(signals: &[Value], crash: Option<&Value>) -> Option<Value> {
    let first = signals.iter().find(|line| line.get("signal").is_some());
    if first.is_none() && crash.is_none() {
        return None;
    }
    let mut summary = json!({"panicked": crash.is_some()});
    if let Some(line) = first {
        let reused = line.get("sender").and_then(|sender| sender.get("reused")).is_some();
        summary["signal"] = json!(signal_name(line["signal"].as_i64().unwrap_or(0)));
        summary["sender_pid"] = line.get("sender_pid").cloned().unwrap_or(Value::Null);
        if !reused && let Some(name) = sender_name(line) {
            summary["sender_name"] = json!(name);
        }
    }
    Some(summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn term_from(pid: i64, sender: Value) -> Value {
        json!({"signal": libc::SIGTERM, "sender_pid": pid, "sender_uid": 501, "sender": sender})
    }

    #[test]
    fn the_text_names_each_sender_and_the_summary_only_the_first() {
        let signals = [term_from(84954, json!({"name":"bash","ppid":1,"parent_name":"launchd"}))];
        let text = cause_text(&signals, None);
        assert!(
            text.starts_with("SIGTERM from pid 84954 (bash, parent 1 launchd, uid 501);"),
            "{text}"
        );
        assert_eq!(
            cause_summary(&signals, None).unwrap(),
            json!({"panicked": false, "signal":"SIGTERM","sender_pid":84954,"sender_name":"bash"})
        );
    }

    #[test]
    fn a_reused_pid_is_never_named() {
        let signals = [term_from(7, json!({"reused": true}))];
        assert!(cause_text(&signals, None).contains("(exited; pid reused, uid 501)"));
        assert!(cause_summary(&signals, None).unwrap().get("sender_name").is_none());
    }

    #[test]
    fn a_panic_is_text_in_the_log_and_a_flag_in_the_summary() {
        let crash = json!({"thread":"t","message":"boom","location":"a.rs:1:2"});
        let text = cause_text(&[], Some(&crash));
        assert!(text.contains("the host had panicked in thread t: boom (at a.rs:1:2)"), "{text}");
        assert_eq!(cause_summary(&[], Some(&crash)).unwrap(), json!({"panicked": true}));
        assert_eq!(cause_summary(&[], None), None);
    }
}
