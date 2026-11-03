//! Part of `Hub`; see `hub/mod.rs`. A background task started with `notify` (`bg_tasks.rs`; the
//! `acpmux` MCP server's `bg_start` asks for it unless told not to) brings its end to its chat:
//! one message when it exits, is stopped, is killed or is lost, so the agent never has to
//! remember `bg_output`. Leo, 2026-11-03: "hmm claude code desktop's summarization of tool
//! calls/parsing of them seem kinda good? we should bea bel to do that AND have condensed tools
//! that are callable in acpmux/cmux-next..."
//!
//! - The end is learned from the runner's own lock (`bg_run.rs`): a thread per watched task
//!   blocks on it (`flock`), which the runner holds until it wrote its exit, or the kernel frees
//!   when the runner dies. Nothing polls.
//! - The message is a tool's notice (`prompt_provenance::notice`, sender `acpmux`): its title is
//!   the task's summary line (`bg_run::outcome`), its body the last [`NOTICE_LINES`] lines of
//!   output. It is never steered into a running turn: it waits behind it, as a lane's report does.
//! - Once per task: its prompt id is `bg-done-<task>`, sent with `resend`, so a second send (a
//!   restart between the send and the mark) is answered from the chat's log instead of running
//!   again; and once the chat took it, `<task>.notified` beside the record says so, so a
//!   restarted daemon ([`Hub::bg_notify_resume`]) watches only tasks whose end is still owed.
//! - A chat that is stopped, closing or purged, a daemon that is shutting down, and a record of
//!   another folder generation get none (the mark stays unwritten).

use super::bg_tasks::{bg_generation, bg_view};
use super::*;
use crate::bg_run::{self, Record};
use cmux_json::JsonSet as _;
use std::path::Path;

/// Lines of the task's output the message carries at most.
const NOTICE_LINES: usize = 20;
/// Bytes of output read for those lines.
const NOTICE_TAIL: u64 = 4 << 10;
/// The notice's sender.
const SENDER: &str = "acpmux";
/// A notice's prompt id starts with this, then the task's id.
const PROMPT_PREFIX: &str = "bg-done-";

impl Hub {
    /// Watches task `record` of folder `dir` and sends its end to its chat ([`Hub::bg_notify`])
    /// once its runner is gone. Outside a runtime it watches nothing.
    pub(super) fn bg_watch(self: &Arc<Self>, dir: &Path, record: &Record) {
        let Ok(handle) = tokio::runtime::Handle::try_current() else { return };
        let lock = bg_run::lock_path(dir, &record.id);
        let (dir, id) = (dir.to_owned(), record.id.clone());
        let session = record.session_id.clone();
        // Weak: a watch never keeps a dropped hub alive, and a dropped hub sends nothing.
        let hub = Arc::downgrade(self);
        let spawned = std::thread::Builder::new().name("acpmux-bg-watch".into()).spawn(move || {
            wait_unlocked(&lock);
            handle.spawn(async move {
                if let Some(hub) = hub.upgrade() {
                    hub.bg_notify(&dir, &session, &id).await;
                }
            });
        });
        if let Err(e) = spawned {
            tracing::warn!(task = %record.id, "a background task's end cannot be watched: {e}");
        }
    }

    /// At a start: watches every task of every chat folder whose end is still owed (asked for,
    /// not marked sent). One that ended while no daemon ran is sent at once.
    pub(super) fn bg_notify_resume(self: &Arc<Self>) {
        let root = crate::config::home().join("bg");
        for entry in std::fs::read_dir(&root).into_iter().flatten().flatten() {
            // `.purged` and the like are no chat's.
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            let dir = entry.path();
            for record in self.bg_records(&dir) {
                if record.notify && !bg_run::notified_path(&dir, &record.id).exists() {
                    self.bg_watch(&dir, &record);
                }
            }
        }
    }

    /// Sends task `id`'s end to chat `session_id` (module docs), unless it went already.
    async fn bg_notify(self: &Arc<Self>, dir: &Path, session_id: &str, id: &str) {
        if self.stopping.load(Ordering::SeqCst) || bg_run::notified_path(dir, id).exists() {
            return;
        }
        let Some(record) = bg_run::read_record(dir, id).filter(|r| r.notify) else { return };
        // A runner that outlived a purge writes into no later chat of this id.
        if bg_generation(dir, false).ok().as_deref() != Some(record.generation.as_str()) {
            return;
        }
        let session =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(session_id).cloned();
        let Some(session) = session else { return };
        if session.closing.load(Ordering::SeqCst)
            || session.purged.load(Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
        {
            return;
        }
        let view = bg_view(dir, &record, 0);
        let (summary, status) = bg_run::outcome(&view);
        let severity = if status == "ok" { "info" } else { "warn" };
        let notice = json!({"sender": SENDER, "severity": severity, "title": summary});
        let body = notice_body(dir, &record);
        let text = crate::prompt_provenance::notice_text(&notice, &body);
        let mut provenance = crate::prompt_provenance::notice(&notice, &session.id);
        provenance.set("bgTaskId", json!(id));
        let mark = bg_run::notified_path(dir, id);
        let opts = PromptOptions {
            prompt_id: Some(format!("{PROMPT_PREFIX}{id}")),
            // A send the chat took before a restart is answered from its log, never run again.
            resend: true,
            provenance: Some(provenance),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Result),
            // Taken (or a duplicate of one taken): never sent again.
            on_accepted: Some(Box::new(move |_| {
                if let Err(e) = std::fs::write(&mark, b"") {
                    tracing::warn!(mark = %mark.display(), "a sent task end was not marked: {e}");
                }
            })),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        // Never steered: it waits for a running turn to end.
        if let Err(e) = self.prompt_with(&session, blocks, SENDER, false, opts).await {
            // Held for a person who resumes the pair: it goes in then.
            if e.data.as_ref().is_none_or(|d| d["held"] != true) {
                tracing::warn!(session = %session.id, task = %id, "a task's end: {}", e.message);
            }
        }
    }
}

/// The message's body: the task's id and command, and its last [`NOTICE_LINES`] lines.
fn notice_body(dir: &Path, record: &Record) -> String {
    let read = bg_run::read_output(dir, &record.id, None, NOTICE_TAIL).unwrap_or_default();
    let text = String::from_utf8_lossy(&read.data);
    let mut lines: Vec<&str> = text.lines().collect();
    // A read that starts mid-output starts mid-line: that piece goes.
    if read.start > 0 && !lines.is_empty() {
        lines.remove(0);
    }
    let from = lines.len().saturating_sub(NOTICE_LINES);
    let tail = lines.get(from..).unwrap_or_default();
    let mut body = format!("Task {}: {}", record.id, bg_run::label(None, &record.command));
    if tail.is_empty() {
        body.push_str("\nIt wrote no output.");
    } else {
        body.push_str(&format!("\nLast {} lines of its output:\n", tail.len()));
        body.push_str(&tail.join("\n"));
        body.push_str("\n(bg_output reads all of it.)");
    }
    body
}

/// Blocks until nothing holds the lock at `path` (a missing file holds nothing), then lets go.
#[cfg(unix)]
fn wait_unlocked(path: &Path) {
    use std::os::fd::AsRawFd;
    let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open(path) else { return };
    loop {
        // SAFETY: flock on a descriptor this function owns; it blocks until the runner let go.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
            // SAFETY: same descriptor; released at once, so a liveness probe sees it free.
            unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
            return;
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return;
        }
    }
}
#[cfg(not(unix))]
fn wait_unlocked(_path: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;

    /// The body names the task and carries only its last lines; a cut first line goes.
    #[test]
    fn a_notice_body_carries_the_last_lines() {
        let dir = cmux_unix_socket::short_test_dir("bg-notice");
        let mut spool = bg_run::Spool::create(dir.path(), "t", 1 << 20).unwrap();
        let out: String = (0..30).map(|i| format!("line-{i}\n")).collect();
        spool.write(out.as_bytes()).unwrap();
        let record = Record { id: "t".into(), command: "make  test\n".into(), ..Record::default() };
        let body = notice_body(dir.path(), &record);
        assert!(body.starts_with("Task t: make test\nLast 20 lines"), "{body}");
        assert!(body.contains("line-10\n") && body.contains("line-29\n"), "{body}");
        assert!(!body.contains("line-9\n"), "{body}");
        let quiet = Record { id: "none".into(), command: "true".into(), ..Record::default() };
        assert!(notice_body(dir.path(), &quiet).ends_with("It wrote no output."));
    }
}
