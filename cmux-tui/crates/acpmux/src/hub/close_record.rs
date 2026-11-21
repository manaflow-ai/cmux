//! Why and when a chat closed: the `closed` record a close writes on its metadata and in its
//! `status` event, which `session info`, `ls --all` and `last` show.
//!
//! An agent diagnosing why `interim-coord` closed found nothing: `session info` had no close
//! time, reason, exit status or signal, and `daemon.log` had no line on the close (Leo,
//! 2026-11-21: "when you guys encounter errors or whatnot, the tool itself should be improved").
//! Every close goes through `kill_held` (`turns.rs`), so the record is written there, from what
//! the closer noted first ([`Hub::note_close`]): a request names its caller (the client, the
//! socket peer's pid, the proven acpmux session it runs in, the command line its CLI declared);
//! the daemon's own closes name their cause. The record also keeps the agent process's exit
//! (code or signal) when acpmux saw one, and, for a chat whose process registered itself
//! (`origin.pid`), whether that process still ran at the close.
//!
//! Shape: `{at, reason, by?, detail?, exit?: {code?, signal?, at, pid?}, origin?: {pid, running}}`.
//! A reopen clears it from the metadata; the log keeps every close's record.

use super::{Hub, Session};
use crate::store::SessionMeta;
use serde_json::{Map, Value, json};

/// The reasons a close records. A stop request is `stopped` (`deleted` with purge); the daemon's
/// own closes say what ended the chat.
pub(crate) mod reason {
    /// `acpmux stop`, `session/close`, the app's close: someone asked.
    pub const STOPPED: &str = "stopped";
    /// `acpmux session delete` / `stop --purge`, `session/delete`.
    pub const DELETED: &str = "deleted";
    /// The connection that made an ephemeral chat (`exec`) closed (`server/ephemeral.rs`).
    pub const CLIENT_CLOSED: &str = "client_closed";
    /// Moved to another daemon (`transfer_out.rs`).
    pub const MOVED: &str = "moved";
}

/// What the next close of a chat records: why, and who asked.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct CloseCause {
    pub reason: &'static str,
    /// The caller, for a request: `{method, client?, pid?, session?, command?}`.
    pub by: Option<Value>,
    pub detail: Option<String>,
}

impl CloseCause {
    pub(crate) fn new(reason: &'static str) -> Self {
        Self { reason, by: None, detail: None }
    }

    pub(crate) fn by(mut self, by: Value) -> Self {
        self.by = Some(by).filter(|b| b.as_object().is_some_and(|o| !o.is_empty()));
        self
    }
}

/// The longest command line a record keeps: a prompt passed as words can be long.
const MAX_COMMAND_CHARS: usize = 300;

/// The command line a CLI request declares (`_meta.acpmux.command`), bounded. A claim, kept as
/// what the caller said, never checked.
pub(crate) fn declared_command(params: &Value) -> Option<String> {
    let command = params.pointer("/_meta/acpmux/command")?.as_str()?.trim();
    (!command.is_empty()).then(|| bounded(command))
}

fn bounded(text: &str) -> String {
    if text.chars().count() <= MAX_COMMAND_CHARS {
        return text.to_owned();
    }
    let mut kept: String = text.chars().take(MAX_COMMAND_CHARS).collect();
    kept.push('…');
    kept
}

/// The close record `cause` makes at `at`, with the agent's last exit and the registered
/// process's state at the close.
pub(crate) fn record(
    cause: &CloseCause,
    at: u64,
    exit: Option<&Value>,
    origin: Option<(u32, bool)>,
) -> Value {
    let mut out = Map::new();
    out.insert("at".into(), json!(at));
    out.insert("reason".into(), json!(cause.reason));
    if let Some(by) = &cause.by {
        out.insert("by".into(), by.clone());
    }
    if let Some(detail) = &cause.detail {
        out.insert("detail".into(), json!(detail));
    }
    if let Some(exit) = exit {
        out.insert("exit".into(), exit.clone());
    }
    if let Some((pid, running)) = origin {
        out.insert("origin".into(), json!({"pid": pid, "running": running}));
    }
    Value::Object(out)
}

/// An agent process's exit: its code, or the signal that ended it.
pub(crate) fn exit_value(
    pid: Option<u32>,
    code: Option<i32>,
    signal: Option<i32>,
    at: u64,
) -> Value {
    let mut out = Map::new();
    out.insert("at".into(), json!(at));
    if let Some(pid) = pid {
        out.insert("pid".into(), json!(pid));
    }
    if let Some(code) = code {
        out.insert("code".into(), json!(code));
    }
    if let Some(signal) = signal {
        out.insert("signal".into(), json!(signal));
        if let Some(name) = signal_name(signal) {
            out.insert("signalName".into(), json!(name));
        }
    }
    Value::Object(out)
}

fn signal_name(signal: i32) -> Option<&'static str> {
    Some(match signal {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        6 => "SIGABRT",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        _ => return None,
    })
}

/// One line for a close record: `stopped 3m ago by acpmux session stop lane (pid 42, from
/// session coord); agent exited 1; registered process 12067 gone`. `now` dates it.
pub fn describe(closed: &Value, now: u64) -> String {
    let mut line =
        closed.get("reason").and_then(Value::as_str).unwrap_or("closed").replace('_', " ");
    if let Some(at) = closed.get("at").and_then(Value::as_u64) {
        line.push_str(&format!(" {} ago", crate::cli::ls_table::ago(now, at)));
    }
    if let Some(by) = closed.get("by") {
        let mut parts = Vec::new();
        if let Some(command) = by.get("command").and_then(Value::as_str) {
            parts.push(command.to_owned());
        } else if let Some(method) = by.get("method").and_then(Value::as_str) {
            parts.push(method.to_owned());
        }
        let mut from = Vec::new();
        if let Some(pid) = by.get("pid").and_then(Value::as_u64) {
            from.push(format!("pid {pid}"));
        }
        if let Some(session) = by.get("sessionName").or(by.get("session")).and_then(Value::as_str) {
            from.push(format!("from session {session}"));
        } else if let Some(client) = by.get("client").and_then(Value::as_str) {
            from.push(client.to_owned());
        }
        if !from.is_empty() {
            parts.push(format!("({})", from.join(", ")));
        }
        if !parts.is_empty() {
            line.push_str(" by ");
            line.push_str(&parts.join(" "));
        }
    }
    if let Some(detail) = closed.get("detail").and_then(Value::as_str) {
        line.push_str(&format!(": {detail}"));
    }
    if let Some(exit) = closed.get("exit") {
        let how = match (exit.get("signalName").or(exit.get("signal")), exit.get("code")) {
            (Some(signal), _) => {
                format!("killed by {}", signal.as_str().map_or(signal.to_string(), str::to_owned))
            }
            (None, Some(code)) => format!("exited {code}"),
            (None, None) => "exited".into(),
        };
        line.push_str(&format!("; agent {how}"));
    }
    if let Some(origin) = closed.get("origin") {
        let pid = origin.get("pid").and_then(Value::as_u64).unwrap_or(0);
        let state = if origin.get("running").and_then(Value::as_bool) == Some(true) {
            "still running"
        } else {
            "gone"
        };
        line.push_str(&format!("; registered process {pid} {state}"));
    }
    line
}

/// Whether process `pid` runs now: the kernel's answer to signal 0 (a process another user owns
/// runs too).
fn running(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let Ok(pid) = i32::try_from(pid) else { return false };
        if pid <= 0 {
            return false;
        }
        // SAFETY: signal 0 checks the pid; it sends nothing.
        let r = unsafe { libc::kill(pid, 0) };
        r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

/// The pid a chat's own process registered (`origin.pid`, `desktop_bridge.rs` `tags_of`).
fn origin_pid(meta: &SessionMeta) -> Option<u32> {
    meta.tags.get("origin.pid")?.value.parse().ok()
}

impl Hub {
    /// Notes why `session`'s next close happens. The first note stands until a close takes it
    /// ([`Self::take_close_cause`]); a refused stop takes its own note back.
    pub(crate) fn note_close(&self, session: &Session, cause: CloseCause) {
        let mut slot = session.close_cause.lock().unwrap_or_else(|e| e.into_inner());
        if slot.is_none() {
            *slot = Some(cause);
        }
    }

    pub(super) fn take_close_cause(&self, session: &Session) -> Option<CloseCause> {
        session.close_cause.lock().unwrap_or_else(|e| e.into_inner()).take()
    }

    /// `kill`, recording `cause` as why the chat closed.
    pub(crate) async fn kill_because(
        &self,
        session: &std::sync::Arc<Session>,
        purge: bool,
        cause: CloseCause,
    ) -> Result<(), crate::rpc::RpcError> {
        self.note_close(session, cause);
        let r = self.kill(session, purge).await;
        if r.is_err() {
            self.take_close_cause(session);
        }
        r
    }

    /// `stop`, recording `cause` as why the chat closed; a refused stop records nothing.
    pub(crate) async fn stop_because(
        &self,
        session: &std::sync::Arc<Session>,
        purge: bool,
        condition: super::stop_if_idle::StopCondition,
        cause: CloseCause,
    ) -> Result<(), crate::rpc::RpcError> {
        self.note_close(session, cause);
        let r = self.stop(session, purge, condition).await;
        if r.is_err() {
            self.take_close_cause(session);
        }
        r
    }

    /// Writes the close record on `session`'s metadata, before its status turns closed (whose
    /// event carries it). Nothing for a chat already closed: a second stop is no close.
    /// `child_exit` is the agent's exit the close itself saw (its kill).
    pub(super) fn write_close_record(
        &self,
        session: &Session,
        purge: bool,
        child_exit: Option<Value>,
    ) {
        let cause = self.take_close_cause(session).unwrap_or_else(|| {
            CloseCause::new(if purge { reason::DELETED } else { reason::STOPPED })
        });
        let exit = {
            let mut last = session.last_exit.lock().unwrap_or_else(|e| e.into_inner());
            if child_exit.is_some() {
                last.clone_from(&child_exit);
            }
            last.clone()
        };
        let now = crate::store::now_ms();
        let record = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if m.status == crate::store::SessionStatus::Closed {
                return;
            }
            let origin = origin_pid(&m).map(|pid| (pid, running(pid)));
            let record = record(&cause, now, exit.as_ref(), origin);
            m.closed = Some(record.clone());
            record
        };
        tracing::info!(
            target: "acpmux::lifecycle",
            session = %session.id,
            name = %session.read_meta(|m| m.name.clone()),
            closed = %record,
            "session closed: {}",
            describe(&record, now)
        );
    }

    /// Notes an agent process's exit on `session`: the next close records it.
    pub(super) fn note_agent_exit(
        &self,
        session: &Session,
        pid: Option<u32>,
        code: Option<i32>,
        signal: Option<i32>,
    ) {
        let mut last = session.last_exit.lock().unwrap_or_else(|e| e.into_inner());
        // A stop that ended this process recorded its status already; the reaper's later word
        // on it says less (the stop reaped it).
        if pid.is_some()
            && last.as_ref().and_then(|l| l.get("pid")).and_then(Value::as_u64)
                == pid.map(u64::from)
        {
            return;
        }
        let exit = exit_value(pid, code, signal, crate::store::now_ms());
        tracing::info!(
            target: "acpmux::lifecycle",
            session = %session.id,
            exit = %exit,
            "agent process exited"
        );
        *last = Some(exit);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_says_when_why_who_and_how_the_agent_ended() {
        let by = json!({"method": "_acpmux/kill", "pid": 42, "sessionName": "coord",
            "command": "acpmux session stop lane"});
        let cause = CloseCause::new(reason::STOPPED).by(by);
        let exit = exit_value(Some(7), None, Some(15), 900);
        let r = record(&cause, 1_000, Some(&exit), Some((12067, false)));
        assert_eq!(r["at"], 1_000);
        assert_eq!(r["reason"], "stopped");
        assert_eq!(r["by"]["pid"], 42);
        assert_eq!(r["exit"]["signal"], 15);
        assert_eq!(r["exit"]["signalName"], "SIGTERM");
        assert_eq!(r["origin"], json!({"pid": 12067, "running": false}));
        let line = describe(&r, 61_000);
        assert_eq!(
            line,
            "stopped 1m ago by acpmux session stop lane (pid 42, from session coord); \
             agent killed by SIGTERM; registered process 12067 gone"
        );
    }

    #[test]
    fn a_bare_record_still_reads() {
        let r = record(&CloseCause::new(reason::CLIENT_CLOSED), 5, None, None);
        assert_eq!(r, json!({"at": 5, "reason": "client_closed"}));
        assert_eq!(describe(&r, 5), "client closed 0s ago");
        let exited = exit_value(None, Some(1), None, 5);
        let r = record(&CloseCause::new(reason::STOPPED), 5, Some(&exited), None);
        assert!(describe(&r, 5).ends_with("; agent exited 1"), "{}", describe(&r, 5));
    }

    #[test]
    fn an_empty_caller_is_no_caller_and_a_long_command_is_cut() {
        assert_eq!(CloseCause::new(reason::STOPPED).by(json!({})).by, None);
        let long = "x".repeat(MAX_COMMAND_CHARS + 50);
        let params = json!({"_meta": {"acpmux": {"command": long}}});
        let kept = declared_command(&params).unwrap();
        assert_eq!(kept.chars().count(), MAX_COMMAND_CHARS + 1);
        assert_eq!(declared_command(&json!({})), None);
    }

    #[test]
    fn this_process_runs_and_pid_zero_does_not() {
        assert!(running(std::process::id()));
        assert!(!running(0));
    }
}

#[cfg(test)]
mod hub_tests {
    use super::super::*;
    use super::{CloseCause, reason};

    /// A hub with one chat on the stand-in agent, never started.
    async fn chat() -> (Arc<Hub>, Arc<Session>) {
        use crate::config::{Config, StoreMode};
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let cfg =
            json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
        let mut cfg: Config = serde_json::from_value(cfg).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let session = hub.new_session(req).await.unwrap();
        (hub, session)
    }

    fn closes(hub: &Hub, s: &Session) -> Vec<Value> {
        hub.events(&s.id, 0, 100_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.dir == "mux" && e.kind == "status" && e.msg["status"] == "closed")
            .map(|e| e.msg)
            .collect()
    }

    #[tokio::test]
    async fn a_close_records_when_why_and_who_on_the_chat_and_in_its_event() {
        let (hub, s) = chat().await;
        let by = json!({"method": "_acpmux/kill", "pid": 4242, "command": "acpmux stop lane"});
        let before = crate::store::now_ms();
        hub.kill_because(&s, false, CloseCause::new(reason::STOPPED).by(by.clone())).await.unwrap();
        let closed = s.meta().closed.expect("a close record");
        assert_eq!(closed["reason"], "stopped", "{closed}");
        assert_eq!(closed["by"], by, "{closed}");
        assert!(closed["at"].as_u64().unwrap() >= before, "{closed}");
        // The status event carries the same record; the summary and the details show it.
        assert_eq!(closes(&hub, &s), vec![json!({"status": "closed", "closed": closed})]);
        assert_eq!(hub.session_summary(&s)["closed"], closed);
        let detail = hub.session_detail(&s);
        assert_eq!(detail["closedAt"], closed["at"]);
        assert_eq!(detail["closeReason"], "stopped");
        // A second stop of a closed chat is no close: the first record stands.
        hub.kill_because(&s, false, CloseCause::new(reason::MOVED)).await.unwrap();
        assert_eq!(s.meta().closed.as_ref(), Some(&closed));
        assert_eq!(closes(&hub, &s).len(), 1);
        // A reopen clears it; the next close without a note is a plain stop.
        assert!(hub.test_reopen(&s.id));
        assert_eq!(s.meta().closed, None);
        assert_eq!(hub.session_detail(&s)["closedAt"], Value::Null);
        hub.kill(&s, false).await.unwrap();
        assert_eq!(s.meta().closed.unwrap()["reason"], "stopped");
    }

    #[tokio::test]
    async fn an_agent_exit_and_a_gone_registered_process_are_recorded() {
        let (hub, s) = chat().await;
        // A pid no process has: what a registered process that went away leaves.
        let gone = u32::try_from(i32::MAX).unwrap();
        let mut tags = serde_json::Map::new();
        tags.insert("origin.pid".into(), json!(gone.to_string()));
        hub.set_tags(&s, Some(&tags), &[], None);
        // The stop ends the running stand-in agent itself: its exit is the close's.
        let pid = s.child.lock().await.as_ref().and_then(|c| c.pid);
        hub.kill(&s, false).await.unwrap();
        let closed = s.meta().closed.unwrap();
        if let Some(pid) = pid {
            assert_eq!(closed["exit"]["pid"], pid, "{closed}");
            assert!(
                closed["exit"].get("signal").or(closed["exit"].get("code")).is_some(),
                "{closed}"
            );
        }
        // An exit acpmux saw before the stop, with no agent left to end: that one. The reopened
        // chat's reader first takes the stopped agent's own exit, which changes nothing.
        assert!(hub.test_reopen(&s.id));
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        hub.note_agent_exit(&s, Some(77), None, Some(9));
        hub.kill(&s, false).await.unwrap();
        let closed = s.meta().closed.unwrap();
        assert_eq!(closed["exit"]["pid"], 77, "{closed}");
        assert_eq!(closed["exit"]["signal"], 9, "{closed}");
        assert_eq!(closed["exit"]["signalName"], "SIGKILL", "{closed}");
        assert_eq!(closed["origin"], json!({"pid": gone, "running": false}), "{closed}");
        let line = super::describe(&closed, crate::store::now_ms());
        assert!(line.contains("agent killed by SIGKILL"), "{line}");
        assert!(line.contains(&format!("registered process {gone} gone")), "{line}");
    }

    #[tokio::test]
    async fn a_refused_stop_leaves_no_note_for_a_later_close() {
        let (hub, s) = chat().await;
        hub.note_close(&s, CloseCause::new(reason::CLIENT_CLOSED));
        assert!(hub.take_close_cause(&s).is_some());
        assert!(hub.take_close_cause(&s).is_none());
        // The first note stands until a close takes it.
        hub.note_close(&s, CloseCause::new(reason::MOVED));
        hub.note_close(&s, CloseCause::new(reason::CLIENT_CLOSED));
        hub.kill(&s, false).await.unwrap();
        assert_eq!(s.meta().closed.unwrap()["reason"], "moved");
    }

    /// What the daemon writes to `daemon.log` meanwhile: the tracing lines of this thread.
    #[derive(Clone, Default)]
    struct Lines(Arc<std::sync::Mutex<Vec<u8>>>);

    impl std::io::Write for Lines {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn daemon_log_has_each_open_and_close_with_its_reason() {
        let lines = Lines::default();
        let writer = lines.clone();
        let subscriber =
            tracing_subscriber::fmt().with_writer(move || writer.clone()).with_ansi(false).finish();
        let _logging = tracing::subscriber::set_default(subscriber);
        let (hub, s) = chat().await;
        let by = json!({"method": "session/close", "pid": 31337});
        hub.kill_because(&s, false, CloseCause::new(reason::STOPPED).by(by)).await.unwrap();
        let text = String::from_utf8(lines.0.lock().unwrap().clone()).unwrap();
        assert!(text.contains("session opened"), "{text}");
        assert!(text.contains("session closed: stopped"), "{text}");
        assert!(text.contains("pid 31337"), "{text}");
        assert!(text.contains(&s.id), "{text}");
    }
}
