//! Part of `Hub`; see `hub/mod.rs`. A background task started with `notify` (`bg_tasks.rs`; the
//! `acpmux` MCP server's `bg_start` asks for it unless told not to) brings its end to its chat:
//! one message when it exits, is stopped, is killed or is lost, so the agent never has to
//! remember `bg_output`. Leo, 2026-11-03: "hmm claude code desktop's summarization of tool
//! calls/parsing of them seem kinda good? we should bea bel to do that AND have condensed tools
//! that are callable in acpmux/cmux-next..."
//!
//! - The end is learned from the runner's own lock (`bg_run.rs`), which the runner holds until
//!   it wrote its exit, or the kernel frees when the runner dies. One thread of the process
//!   (`acpmux-bg-watch`, [`watcher`]) holds every watched task's lock file open and tries each
//!   lock without blocking: the threads stay constant at any task count (a host at load 170 had
//!   42 threads parked in `flock`, one per task, 2026-11-23). On Linux it tries them when one of
//!   the lock files is closed (inotify; the runner's end closes it), else once a [`TICK`]: 50
//!   running tasks woke it 10 times in 10 idle seconds, and a task's end waited half a tick for
//!   its notice (`idle_bench`). A purged chat's tasks leave it ([`Hub::bg_unwatch_session`]).
//! - The message is a tool's notice (`prompt_provenance::notice`, sender `acpmux`): its title is
//!   the task's summary line (`bg_run::outcome`), its body the last [`NOTICE_LINES`] lines of
//!   output. A chat whose turn runs reads it at that turn's next tool step, as a lane's report
//!   steers in (`lane_reports.rs`): queued behind the turn, it was a turn of its own once the turn
//!   ended, and 92 of 382 such turns in a day did nothing (no tool, or only a wait or a status
//!   read; median 125k tokens each, 13.4M tokens a day on one lane VM, cmuxterm-hq
//!   `tools/transcript-analytics/tx_noop_turns.py`, 2026-11-24). An idle chat gets it as a turn
//!   of its own; a turn it may not steer into (the person's own, one past its cap, a review's, an
//!   agent that does not steer) or that ends before the agent read it gets it after, as before
//!   (`turns.rs` `run_prompt_joined`, `steer_end.rs`). Leo, 2026-11-24: "anyways, for these
//!   transcript analyses, we can likely do more tooling on things. and expand on our current
//!   repertoir."
//! - Once per task: its prompt id is `bg-done-<task>`, sent with `resend`, so a second send (a
//!   restart between the send and the mark) is answered from the chat's log instead of running
//!   again; and once the chat took it, `<task>.notified` beside the record says so, so a
//!   restarted daemon ([`Hub::bg_notify_resume`]) watches only tasks whose end is still owed.
//! - A chat that is stopped, closing or purged, a daemon that is shutting down, and a record of
//!   another folder generation get none (the mark stays unwritten).
//! - A task a Claude Code subagent started through MCP (`Record::subagent`, `subagent_call.rs`)
//!   brings its end to that subagent while it runs, as a lane's no-wait report does
//!   (`lane_report_subagents.rs`): left in its folder, handed over after its next Bash or acpmux
//!   MCP call, and marked sent once left. One it never took, or one that ended after it stopped
//!   or while no subagent runs, goes to the chat, saying whose it was (W5-M, 2026-11-08: the end of a subagent's
//!   `acpmux run` task carried a lane's reply into its lead's chat). One that went well waits in
//!   the chat's inbox for its next turn (or the held result's deadline), as a coordinator's does;
//!   a failed one wakes it ([`holds_end`]). The lead's own end that went well, in an idle chat,
//!   waits too, but only [`OWN_END_HOLD_MS`], so ends that come together wake it once
//!   ([`end_hold`]).

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
pub(super) const PROMPT_PREFIX: &str = "bg-done-";

impl Hub {
    /// Watches task `record` of folder `dir` and, once its runner is gone, logs its ended row in
    /// the process registry (`bg_registry.rs`) and sends its end to its chat ([`Hub::bg_notify`],
    /// a task with `notify`). Outside a runtime it watches nothing.
    pub(super) fn bg_watch(self: &Arc<Self>, dir: &Path, record: &Record) {
        let Ok(handle) = tokio::runtime::Handle::try_current() else { return };
        let lock = bg_run::lock_path(dir, &record.id);
        let (dir, id) = (dir.to_owned(), record.id.clone());
        let session = record.session_id.clone();
        // Weak: a watch never keeps a dropped hub alive, and a dropped hub sends nothing.
        let hub = Arc::downgrade(self);
        let owner = Arc::as_ptr(self) as usize;
        // A stopping hub sends nothing (`bg_notify`), so it no longer holds the watch.
        let alive = hub.clone();
        let alive = move || alive.upgrade().is_some_and(|h| !h.stopping.load(Ordering::SeqCst));
        watcher().watch(lock, owner, record.session_id.clone(), alive, move || {
            handle.spawn(async move {
                if let Some(hub) = hub.upgrade() {
                    hub.bg_ended(&dir, &session, &id);
                    hub.bg_notify(&dir, &session, &id).await;
                }
            });
        });
    }

    /// Stops watching the tasks of chat `session_id` (it is purged): their ends go nowhere, and
    /// a runner that outlives the purge holds no watch.
    pub(super) fn bg_unwatch_session(&self, session_id: &str) {
        watcher().unwatch(std::ptr::from_ref(self) as usize, session_id);
    }

    /// Stops every watch of this hub (it shut down): a hub shut down in this process may live
    /// on (its loops hold it until the daemon stops), and its watch kept would take the end a
    /// restarted hub's pass watches for (`Watcher::watch` keeps the first live watch of a lock).
    pub(super) fn bg_unwatch_all(&self) {
        watcher().unwatch_owner(std::ptr::from_ref(self) as usize);
    }

    /// At a start: watches every task of every chat folder that still runs, or whose end is still
    /// owed (asked for, not marked sent), and logs each running one's registry row
    /// (`bg_registry.rs`). One owed that ended while no daemon ran is sent at once.
    ///
    /// It reads only the records whose folder listing shows no `.notified` mark: on the owner's
    /// Mac 5,000 of 6,043 records had one (2026-11-11).
    pub(super) fn bg_notify_resume(self: &Arc<Self>) {
        let root = crate::config::home().join("bg");
        // Only this hub's chats: an end goes nowhere but a chat it holds (`bg_notify`), and the
        // first live watch of a lock keeps it (`Watcher::watch`), so a watch taken for another
        // hub's chat (hubs of one home in one process) would swallow the end that hub owes.
        let held: std::collections::HashSet<String> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).keys().cloned().collect();
        for entry in std::fs::read_dir(&root).into_iter().flatten().flatten() {
            // `.purged` and the like are no chat's.
            if entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            // A chat's folder is named by its id (`bg_run`): another hub's is not read at all.
            if !held.contains(entry.file_name().to_string_lossy().as_ref()) {
                continue;
            }
            let dir = entry.path();
            let Ok(generation) = bg_generation(&dir, false) else { continue };
            let names: std::collections::HashSet<String> = std::fs::read_dir(&dir)
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| e.file_name().into_string().ok())
                .collect();
            for name in &names {
                let Some(id) = name.strip_suffix(".json") else { continue };
                if names.contains(&format!("{id}.notified")) {
                    continue;
                }
                let Some(record) = bg_run::read_record(&dir, id) else { continue };
                if !held.contains(&record.session_id) || record.generation != generation {
                    continue;
                }
                let owed = record.notify && !bg_run::notified_path(&dir, &record.id).exists();
                let running = record.ended_at.is_none();
                if owed || running {
                    self.bg_watch(&dir, &record);
                }
                if running && let Some(session) = self.session_get(&record.session_id) {
                    self.bg_publish(&session, &dir, &record);
                }
            }
        }
    }

    /// [`Self::bg_notify_resume`] on a thread of its own, after the store is ready: it reads a
    /// file per task of every chat, thousands at a start, cold after an update (8.9 s on a
    /// fleet Mac's disk), and nothing that answers a request or adopts an agent waits on it.
    /// A task's end it finds owed reaches its chat a little later, as one that ends now does.
    pub(super) fn bg_notify_resume_in_background(self: &Arc<Self>) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return self.bg_notify_resume();
        };
        // Weak: the pass never keeps a dropped hub alive.
        let hub = Arc::downgrade(self);
        let spawned =
            std::thread::Builder::new().name("acpmux-bg-resume".into()).spawn(move || {
                // Its watches spawn onto the daemon's runtime (`bg_watch`).
                let _runtime = runtime.enter();
                if let Some(hub) = hub.upgrade() {
                    hub.bg_notify_resume();
                }
            });
        if let Err(e) = spawned {
            tracing::warn!("the owed ends of background tasks cannot be watched: {e}");
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
        let session = self.session_get(session_id);
        let Some(session) = session else { return };
        // The task no longer holds its chat's idle period up (`idle_governor.rs`): the reaper
        // takes the new deadline.
        self.idle_wake.notify_one();
        if session.closing.load(Ordering::SeqCst)
            || session.purged.load(Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
        {
            return;
        }
        // A subagent's task: its end goes to that subagent while it runs, as a lane's report.
        if let Some(sub) = &record.subagent
            && self.bg_end_to_subagent(&session, dir, &record, sub)
        {
            return;
        }
        // Its subagent stopped, or none runs: the chat gets it, saying whose it was.
        self.bg_end_to_chat(&session, dir, &record, record.subagent.as_ref()).await;
    }

    /// Sends task `record`'s end to its chat `session`, saying it is for subagent `ended` (one
    /// that started the task and ended before it took the end).
    async fn bg_end_to_chat(
        self: &Arc<Self>,
        session: &Arc<Session>,
        dir: &Path,
        record: &Record,
        ended: Option<&Value>,
    ) {
        let id = record.id.as_str();
        let notice = end_notice(dir, record);
        let (mut body, wrote) = notice_body(dir, record);
        if let Some(label) = super::lane_report_subagents::label(ended) {
            body.push_str(&format!(
                "\nThis task end is for your {label}, which started the task and has ended, so it \
comes to you."
            ));
        }
        let display = orphan_display(ended.is_some(), wrote, &notice);
        let mark = bg_run::notified_path(dir, id);
        // A task end with nothing to say to anyone (its subagent ended, it went well, it wrote
        // nothing) is not sent: it counts as sent, so no restart owes it (Leo, 2026-11-12, on a
        // chat of such ends: "What the h*** is this?").
        if display == Some("none") {
            if let Err(e) = crate::home_fs::write(&mark, b"") {
                tracing::warn!(mark = %mark.display(), "a dropped task end was not marked: {e}");
            }
            return;
        }
        let text = crate::prompt_provenance::notice_text(&notice, &body);
        let mut provenance = crate::prompt_provenance::notice(&notice, &session.id);
        provenance.set("bgTaskId", json!(id));
        // What the chat's chip calls it: its own description, else "Background task".
        if let Some(description) =
            record.description.as_deref().map(str::trim).filter(|d| !d.is_empty())
        {
            provenance.set("bgTaskDescription", json!(description));
        }
        if let Some(sub) = ended {
            provenance.set(super::lane_report_subagents::FOR_SUBAGENT, sub.clone());
        }
        // How the chat draws it: one quiet line; the agent reads the whole text.
        if let Some(display) = display {
            provenance.set(DISPLAY, json!(display));
        }
        // A task end that went well starts no turn of its own when it is a coordinator's, or
        // when the subagent that started it ended before it ([`holds_end`]): it waits in the
        // chat's inbox and goes with the next turn it takes (`inbox_page_rule.rs`), or its
        // deadline brings it. One that failed wakes the chat, as does the lead's own end in a
        // chat not on the list. Left in the inbox it counts as sent: the log restores it, and a
        // send again finds it there.
        let prompt_id = format!("{PROMPT_PREFIX}{id}");
        let ok = notice.get("severity").and_then(Value::as_str) == Some("info");
        let listed = self.page_rule_lists(&session.meta().name);
        // The lead's own exit-0 end in an idle plain chat that ran a turn waits too, but only
        // [`OWN_END_HOLD_MS`]: ends that come close together, or with another message, wake the
        // chat once ([`end_hold`]). Into a running turn it steers at the next tool step as
        // before, and a chat that never ran a turn takes it as its first work.
        let idle = session.turn().is_none() && session.meta().turn_count > 0;
        let hold = end_hold(ok, listed, ended.is_some(), idle);
        if let Some(within) = hold.flatten() {
            provenance.set(crate::prompt_provenance::WITHIN, json!(within));
        }
        if hold.is_some() && self.inbox_hold_end(session, &prompt_id, &text, &provenance) {
            if let Err(e) = crate::home_fs::write(&mark, b"") {
                tracing::warn!(mark = %mark.display(), "a held task end was not marked: {e}");
            }
            return;
        }
        let opts = PromptOptions {
            prompt_id: Some(prompt_id),
            // A send the chat took before a restart is answered from its log, never run again.
            resend: true,
            provenance: Some(provenance),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Result),
            // Taken (or a duplicate of one taken): never sent again.
            on_accepted: Some(Box::new(move |_| {
                if let Err(e) = crate::home_fs::write(&mark, b"") {
                    tracing::warn!(mark = %mark.display(), "a sent task end was not marked: {e}");
                }
            })),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        // Into a running turn at its next tool step, else a turn of its own (module docs).
        if let Err(e) = self.prompt_with(session, blocks, SENDER, true, opts).await {
            // Held for a person who resumes the pair: it goes in then.
            if e.data.as_ref().is_none_or(|d| d["held"] != true) {
                tracing::warn!(session = %session.id, task = %id, "a task's end: {}", e.message);
            }
        }
    }
}

impl Hub {
    /// Leaves task `record`'s end for subagent `sub` (`{id, type}`) of `session`, which started
    /// it: true when it is left (the subagent's hook hands it over after its next Bash or acpmux
    /// MCP call, `bg_hook.rs`), false when that subagent stopped or none of `session` runs, so
    /// the end goes to `session` itself. Once left, the end counts as sent (`.notified`): a
    /// restart finds it in the subagent's folder (`subagent_notice.rs`), not owed here. A crash
    /// between leaving it and the mark leaves it again at the next start: the subagent may then
    /// read it twice (the chat's path has `resend` for this; the subagent's has none).
    fn bg_end_to_subagent(
        &self,
        session: &Session,
        dir: &Path,
        record: &Record,
        sub: &Value,
    ) -> bool {
        let notice = end_notice(dir, record);
        let text = format!(
            "[acpmux] A background task you started ended:\n{}",
            crate::prompt_provenance::notice_text(&notice, &notice_body(dir, record).0)
        );
        // Only the task's id: the sweep finds its folder from the chat (`bg_end_swept`).
        let left = json!({"text": text, "bgTask": record.id, "forSubagent": sub});
        let prompt_id = format!("{PROMPT_PREFIX}{}", record.id);
        if !self.subagent_notice_leave(session, sub, &prompt_id, &left) {
            return false;
        }
        if let Err(e) = crate::home_fs::write(bg_run::notified_path(dir, &record.id), b"") {
            tracing::warn!(task = %record.id, "a task end left for a subagent was not marked: {e}");
        }
        true
    }

    /// A task end left for a subagent that none took (`lane_report_subagents.rs` sweep): to
    /// chat `session_id`, saying whose it was. Only a task of that chat's own folder, of its
    /// current generation, whose end was asked for. Its sent mark is removed first: until the
    /// chat takes it (`on_accepted` marks it again), a restarted daemon still owes it
    /// ([`Hub::bg_notify_resume`]), so a failed or cut-short send loses nothing.
    pub(super) async fn bg_end_swept(self: &Arc<Self>, session_id: &str, left: &Value) {
        let Some(id) = left
            .get("bgTask")
            .and_then(Value::as_str)
            .filter(|id| crate::subagent_notice::name_word(id))
        else {
            return;
        };
        let session = self.session_get(session_id);
        let Some(session) = session else { return };
        let dir = self.bg_dir(&session);
        let Some(record) = bg_run::read_record(&dir, id)
            .filter(|r| r.notify && r.session_id == session.id)
            .filter(|r| bg_generation(&dir, false).ok().as_deref() == Some(r.generation.as_str()))
        else {
            return;
        };
        let _ = crate::home_fs::remove_file(bg_run::notified_path(&dir, id));
        if self.stopping.load(Ordering::SeqCst)
            || session.closing.load(Ordering::SeqCst)
            || session.purged.load(Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
        {
            return;
        }
        self.bg_end_to_chat(&session, &dir, &record, left.get("forSubagent")).await;
    }
}

/// The end's notice: its outcome as the title, `warn` unless it went well.
fn end_notice(dir: &Path, record: &Record) -> Value {
    let view = bg_view(dir, record, 0);
    let (summary, status) = bg_run::outcome(&view);
    let severity = if status == "ok" { "info" } else { "warn" };
    json!({"sender": SENDER, "severity": severity, "title": summary})
}

/// Whether a task end waits in the chat's inbox instead of starting a turn of its own: one that
/// went well (`ok`), in a coordinator's chat (`listed`, RFD 0041), or whose subagent ended before
/// it (`orphan`). An orphan's end is the leftover of work its subagent already reported on: on one
/// lane VM's transcripts (2026-11-26), 74 of 213 turns such an end started did nothing (35%,
/// against 13% for the lead's own ends), and 167 of the 213 had another turn of the chat within
/// the 15 minutes a held result waits at most (`prompt_class::due_at`), which now carries it.
/// Leo, 2026-11-26: "simply clear th bullshit. theres noway tere's >100 of actually needed
/// stuff much less >400". A failed end still wakes the chat: its exit is the news.
fn holds_end(ok: bool, listed: bool, orphan: bool) -> bool {
    ok && (listed || orphan)
}

/// How long the lead's own exit-0 end waits in a plain chat's inbox before it wakes the chat.
/// One lane's 24 h (one lane VM, 2026-11-26): 1,177 of its 3,060 wakes (38%) were task
/// ends, each a turn of its own, and 28% of all its wakes came less than 5 minutes after the one
/// before. Held this long in an idle chat, ends that come close together, and an end that comes
/// just before another message, go in as one notice. Leo: "us not getting fucking swamped by our
/// own fucking wake-ups, our own tool calls". A failed end, an end while a turn runs (the turn
/// may be waiting on it: it steers in at the next tool step) and an end to a chat that never ran
/// a turn are not held so.
pub(super) const OWN_END_HOLD_MS: u64 = 5 * 60 * 1000;

/// Whether a task end waits in the chat's inbox, and its own deadline there: `None` sends it as
/// a prompt (a failure: its exit is the news); `Some(None)` holds it to its class's deadline
/// ([`holds_end`]); `Some(Some(ms))` holds the lead's own exit-0 end [`OWN_END_HOLD_MS`] when
/// its chat is `idle` (no turn runs, and it ran one).
fn end_hold(ok: bool, listed: bool, orphan: bool, idle: bool) -> Option<Option<u64>> {
    if holds_end(ok, listed, orphan) {
        Some(None)
    } else if ok && idle {
        Some(Some(OWN_END_HOLD_MS))
    } else {
        None
    }
}

/// The provenance field that says how the chat draws a task end (`"none"` or `"line"`).
const DISPLAY: &str = "display";

/// What happens to a task end whose subagent ended before it (`orphan`), so it would come to the
/// lead: one that went well and wrote nothing tells no one anything and is not sent (`"none"`);
/// any other is sent and draws as one quiet line, its output behind it (`"line"`). A failure
/// with no output is still sent: its exit is the news. A task end for the chat's own agent keeps
/// its usual row (`None`) (Leo, 2026-11-12, on such an end drawn as a card: "hm? what happened
/// here").
fn orphan_display(orphan: bool, wrote: bool, notice: &Value) -> Option<&'static str> {
    if !orphan {
        return None;
    }
    let ok = notice.get("severity").and_then(Value::as_str) == Some("info");
    Some(if ok && !wrote { "none" } else { "line" })
}

/// The message's body: the task's id and command, and its last [`NOTICE_LINES`] lines; and
/// whether the task wrote any output.
fn notice_body(dir: &Path, record: &Record) -> (String, bool) {
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
    (body, !tail.is_empty())
}

/// How often the watcher tries the watched locks when it cannot be told of their close: on macOS,
/// and on Linux while a watched lock has no close watch (no inotify, or a lock let go before its
/// watch was added).
const TICK: std::time::Duration = std::time::Duration::from_secs(1);

/// How often the watcher tries every lock anyway while each has its close watch (Linux). A
/// runner's lock is its own open file, which it closes at its end (`drop(lock)` in `bg_run.rs`,
/// or the kernel at its death), so the close event is the news; this only bounds one missed.
#[cfg(target_os = "linux")]
const CLOSE_FALLBACK: std::time::Duration = std::time::Duration::from_secs(30);

/// The process's one watcher of background tasks' locks (module docs).
fn watcher() -> &'static Watcher {
    // test-hook-allow: holds no hook; the daemon's one watcher, each watch keyed by its own lock file, so no test replaces another's
    static WATCHER: std::sync::OnceLock<Watcher> = std::sync::OnceLock::new();
    WATCHER.get_or_init(Watcher::default)
}

/// Lock files watched until nothing holds them; each fires its end once, from one thread.
#[derive(Default)]
struct Watcher {
    state: StdMutex<WatchState>,
    /// Wakes the thread from an idle wait when a watch is added.
    added: std::sync::Condvar,
}

#[derive(Default)]
struct WatchState {
    /// By lock path: a task watched twice (a start and a restart's pass) ends once; a watch whose
    /// hub is gone or stopping gives way to the next.
    watches: HashMap<std::path::PathBuf, Watch>,
    /// The watcher thread runs.
    running: bool,
    /// Linux: the close watches of the locks, and the wake of the thread's wait for them.
    #[cfg(target_os = "linux")]
    closes: Option<Closes>,
}

/// One inotify instance asked only for closes of the watched lock files: the watcher thread
/// sleeps in `poll` on it (and on `wake`) instead of probing every lock once a [`TICK`], so an
/// idle daemon with running background tasks does not wake each second, and a task's end is
/// seen when it comes rather than up to a tick later.
#[cfg(target_os = "linux")]
struct Closes {
    watches: inotify::Watches,
    /// An eventfd: a watch added without a close watch shortens the thread's wait to a tick.
    wake: std::os::fd::OwnedFd,
}

struct Watch {
    /// Held open for the probe; never locked but for a probe.
    file: std::fs::File,
    /// The hub (its address) and the chat the task is of.
    owner: usize,
    session: String,
    /// Whether the hub that watched still runs (not dropped, not stopping).
    alive: Box<dyn Fn() -> bool + Send>,
    end: Box<dyn FnOnce() + Send>,
    /// Its close watch; none: the thread probes it each tick.
    #[cfg(target_os = "linux")]
    close: Option<inotify::WatchDescriptor>,
}

impl WatchState {
    /// Removes the watch of `path`, and its close watch.
    fn remove(&mut self, path: &Path) -> Option<Watch> {
        let watch = self.watches.remove(path)?;
        #[cfg(target_os = "linux")]
        if let (Some(closes), Some(wd)) = (self.closes.as_mut(), watch.close.clone()) {
            let _ = closes.watches.remove(wd);
        }
        Some(watch)
    }

    /// Removes every watch `drop` names, firing none.
    fn remove_where(&mut self, gone_if: impl Fn(&Watch) -> bool) {
        let gone: Vec<_> =
            self.watches.iter().filter(|(_, w)| gone_if(w)).map(|(p, _)| p.clone()).collect();
        for path in gone {
            self.remove(&path);
        }
    }

    /// How long the thread may wait before it probes every lock again.
    fn wait(&self) -> std::time::Duration {
        #[cfg(target_os = "linux")]
        if self.closes.is_some() && self.watches.values().all(|w| w.close.is_some()) {
            return CLOSE_FALLBACK;
        }
        TICK
    }
}

#[cfg(target_os = "linux")]
impl Closes {
    fn open() -> std::io::Result<(Self, inotify::Inotify)> {
        use std::os::fd::FromRawFd;
        let inotify = inotify::Inotify::init()?;
        // SAFETY: eventfd takes no pointers; a nonnegative return is a new descriptor owned here.
        let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `fd` was just opened and nothing else owns it.
        let wake = unsafe { std::os::fd::OwnedFd::from_raw_fd(fd) };
        Ok((Self { watches: inotify.watches(), wake }, inotify))
    }

    /// The close watch of the lock at `path`, opened as `file`. None when it cannot be had, or
    /// when the lock was let go before it was added (that close came before the watch, so no
    /// event will): such a watch is probed each tick, and the thread is woken to wait a tick.
    fn add(&mut self, path: &Path, file: &std::fs::File) -> Option<inotify::WatchDescriptor> {
        use inotify::WatchMask;
        let wd = self.watches.add(path, WatchMask::CLOSE_WRITE | WatchMask::CLOSE_NOWRITE).ok();
        if wd.as_ref().is_some_and(|_| !unlocked(file)) {
            return wd;
        }
        if let Some(wd) = wd {
            let _ = self.watches.remove(wd);
        }
        self.wake_thread();
        None
    }

    fn wake_thread(&self) {
        use std::os::fd::AsRawFd;
        let one = 1u64.to_ne_bytes();
        // SAFETY: writes the 8 bytes of `one` to the eventfd this owns.
        let _ = unsafe { libc::write(self.wake.as_raw_fd(), one.as_ptr().cast(), one.len()) };
    }
}

/// Waits up to `wait` for a close of a watched lock (or a wake), then drains what came.
#[cfg(target_os = "linux")]
fn wait_for_close(
    inotify: &mut inotify::Inotify,
    wake: std::os::fd::RawFd,
    wait: std::time::Duration,
    buffer: &mut [u8],
) {
    use std::os::fd::AsRawFd;
    let mut fds = [
        libc::pollfd { fd: inotify.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        libc::pollfd { fd: wake, events: libc::POLLIN, revents: 0 },
    ];
    let ms = libc::c_int::try_from(wait.as_millis()).unwrap_or(libc::c_int::MAX);
    // SAFETY: `fds` is a valid array of two pollfd for the call.
    let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, ms) };
    if ready <= 0 {
        return;
    }
    while inotify.read_events(buffer).is_ok_and(|mut events| events.next().is_some()) {}
    let mut count = [0u8; 8];
    // SAFETY: reads at most the 8 bytes of `count` from the eventfd (nonblocking).
    let _ = unsafe { libc::read(wake, count.as_mut_ptr().cast(), count.len()) };
}

impl Watcher {
    /// Calls `end` once nothing holds the lock at `path` (a missing file holds nothing: at once).
    fn watch(
        &self,
        path: std::path::PathBuf,
        owner: usize,
        session: String,
        alive: impl Fn() -> bool + Send + 'static,
        end: impl FnOnce() + Send + 'static,
    ) {
        let Ok(file) = crate::home_fs::OpenOptions::new().read(true).write(true).open(&path) else {
            return end();
        };
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        #[cfg(target_os = "linux")]
        let mut reader = None;
        #[cfg(target_os = "linux")]
        if !state.running && state.closes.is_none() {
            match Closes::open() {
                Ok((closes, inotify)) => {
                    state.closes = Some(closes);
                    reader = Some(inotify);
                }
                Err(e) => tracing::debug!("background tasks' ends are probed each tick: {e}"),
            }
        }
        // The first watch of a lock keeps it, unless its hub is gone or stopping: a hub shut down in
        // this process (a restart) leaves its watches behind, and keeping one sends that end nowhere.
        let keep = state.watches.get(&path).is_some_and(|old| (old.alive)());
        if !keep {
            #[cfg(target_os = "linux")]
            let close = match state.watches.get_mut(&path) {
                // The same path's close watch: inotify gives one per file, so it carries over.
                Some(old) => old.close.take(),
                None => state.closes.as_mut().and_then(|c| c.add(&path, &file)),
            };
            let watch = Watch {
                file,
                owner,
                session,
                alive: Box::new(alive),
                end: Box::new(end),
                #[cfg(target_os = "linux")]
                close,
            };
            state.watches.insert(path, watch);
        }
        if !state.running {
            #[cfg(target_os = "linux")]
            let spawned = std::thread::Builder::new()
                .name("acpmux-bg-watch".into())
                .spawn(move || watcher().run(reader));
            #[cfg(not(target_os = "linux"))]
            let spawned = std::thread::Builder::new()
                .name("acpmux-bg-watch".into())
                .spawn(|| watcher().run());
            match spawned {
                Ok(_) => state.running = true,
                Err(e) => {
                    tracing::warn!("background tasks' ends cannot be watched: {e}");
                    // The close watches went with the reader; a later watch opens them again.
                    #[cfg(target_os = "linux")]
                    {
                        state.closes = None;
                        for watch in state.watches.values_mut() {
                            watch.close = None;
                        }
                    }
                }
            }
        }
        self.added.notify_one();
    }

    /// Drops the watches of chat `session` of hub `owner`, firing none.
    fn unwatch(&self, owner: usize, session: &str) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.remove_where(|w| w.owner == owner && w.session == session);
    }

    /// Drops every watch of hub `owner`, firing none.
    fn unwatch_owner(&self, owner: usize) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.remove_where(|w| w.owner == owner);
    }

    /// The watcher thread: idle while nothing is watched, else a probe of every lock after each
    /// close of one (Linux; at most [`CLOSE_FALLBACK`] apart), or each tick.
    fn run(&self, #[cfg(target_os = "linux")] mut reader: Option<inotify::Inotify>) {
        #[cfg(target_os = "linux")]
        let mut buffer = vec![0u8; 4096];
        loop {
            let (ended, wait, wake): (Vec<Watch>, _, Option<i32>) = {
                let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                while state.watches.is_empty() {
                    state = self.added.wait(state).unwrap_or_else(|e| e.into_inner());
                }
                let free: Vec<_> = state
                    .watches
                    .iter()
                    .filter(|(_, w)| unlocked(&w.file))
                    .map(|(p, _)| p.clone())
                    .collect();
                let ended = free.iter().filter_map(|p| state.remove(p)).collect();
                #[cfg(target_os = "linux")]
                let wake = state.closes.as_ref().map(|c| {
                    use std::os::fd::AsRawFd;
                    c.wake.as_raw_fd()
                });
                #[cfg(not(target_os = "linux"))]
                let wake = None;
                (ended, state.wait(), wake)
            };
            // Outside the lock: an end may watch again.
            for watch in ended {
                (watch.end)();
            }
            #[cfg(target_os = "linux")]
            if let (Some(inotify), Some(wake)) = (reader.as_mut(), wake) {
                wait_for_close(inotify, wake, wait, &mut buffer);
                continue;
            }
            let _ = wake;
            std::thread::sleep(wait.min(TICK));
        }
    }
}

/// Whether nothing holds the lock of `file`, without blocking; a probe that takes it lets go
/// at once, so a liveness probe elsewhere sees it free. An interrupted probe counts as held (the
/// next tick tries again); another error as free, as the runner's lock is then no news.
fn unlocked(file: &std::fs::File) -> bool {
    use cmux_file_lock::{FileLock, Kind};
    match FileLock::held_elsewhere(file, Kind::Exclusive) {
        Ok(held) => !held,
        Err(e) => e.kind() != std::io::ErrorKind::Interrupted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::inbox::Item;
    use crate::prompt_class::PromptClass;

    /// The body names the task and carries only its last lines; a cut first line goes.
    #[test]
    fn a_notice_body_carries_the_last_lines() {
        let dir = cmux_unix_socket::short_test_dir("bg-notice");
        let mut spool = bg_run::Spool::create(dir.path(), "t", 1 << 20).unwrap();
        let out: String = (0..30).map(|i| format!("line-{i}\n")).collect();
        spool.write(out.as_bytes()).unwrap();
        let record = Record { id: "t".into(), command: "make  test\n".into(), ..Record::default() };
        let (body, wrote) = notice_body(dir.path(), &record);
        assert!(wrote);
        assert!(body.starts_with("Task t: make test\nLast 20 lines"), "{body}");
        assert!(body.contains("line-10\n") && body.contains("line-29\n"), "{body}");
        assert!(!body.contains("line-9\n"), "{body}");
        let quiet = Record { id: "none".into(), command: "true".into(), ..Record::default() };
        let (body, wrote) = notice_body(dir.path(), &quiet);
        assert!(!wrote);
        assert!(body.ends_with("It wrote no output."));
    }

    /// A task end whose subagent ended draws nothing when it went well with no output, one quiet
    /// line otherwise; the chat's own task end keeps its row.
    #[test]
    fn an_orphan_task_end_is_quiet() {
        let ok = json!({"severity": "info"});
        let failed = json!({"severity": "warn"});
        assert_eq!(orphan_display(true, false, &ok), Some("none"));
        assert_eq!(orphan_display(true, true, &ok), Some("line"));
        assert_eq!(orphan_display(true, false, &failed), Some("line"));
        assert_eq!(orphan_display(false, false, &ok), None);
    }

    /// Number of this process's threads named `acpmux-bg-watch`.
    #[cfg(target_os = "linux")]
    fn watch_threads() -> usize {
        std::fs::read_dir("/proc/self/task")
            .unwrap()
            .flatten()
            .filter(|t| {
                std::fs::read_to_string(t.path().join("comm"))
                    .is_ok_and(|c| c.trim() == "acpmux-bg-watch")
            })
            .count()
    }

    /// A lock file held as a runner holds it, by its own open file.
    fn held_lock(dir: &Path, name: &str) -> (std::path::PathBuf, cmux_file_lock::FileLock) {
        let path = dir.join(format!("{name}.lock"));
        let file = crate::home_fs::create_file(&path).unwrap();
        let held =
            cmux_file_lock::FileLock::try_take(file, cmux_file_lock::Kind::Exclusive).unwrap();
        (path, held)
    }

    /// 200 watched tasks take one thread, not 200; a lock let go fires its end once, within a
    /// tick or two; a purged chat's watches go without firing while their locks are still held.
    #[test]
    fn bg_watch_one_thread_fires_once_and_unwatches() {
        let dir = cmux_unix_socket::short_test_dir("bg-watch");
        let owner = 0xb9_0001;
        let fired = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let (tx, rx) = std::sync::mpsc::channel();
        let mut held = Vec::new();
        for i in 0..200 {
            let (path, file) = held_lock(dir.path(), &format!("t{i}"));
            let session = if i == 0 { "live" } else { "purged" };
            let (fired, tx) = (fired.clone(), tx.clone());
            watcher().watch(
                path,
                owner,
                session.into(),
                || true,
                move || {
                    fired.fetch_add(1, Ordering::SeqCst);
                    let _ = tx.send(i);
                },
            );
            held.push(file);
        }
        #[cfg(target_os = "linux")]
        assert_eq!(watch_threads(), 1, "200 watched tasks take one thread");
        // The purged chat's 199 watches go; their locks stay held.
        watcher().unwatch(owner, "purged");
        let left =
            watcher().state.lock().unwrap().watches.values().filter(|w| w.owner == owner).count();
        assert_eq!(left, 1);
        assert_eq!(fired.load(Ordering::SeqCst), 0, "nothing fired while every lock is held");
        // Every lock let go: only the one still watched fires, once, within the tick.
        let started = std::time::Instant::now();
        drop(held);
        assert_eq!(rx.recv_timeout(TICK * 3).unwrap(), 0);
        assert!(started.elapsed() < TICK * 3);
        std::thread::sleep(TICK * 2);
        assert_eq!(fired.load(Ordering::SeqCst), 1, "one end, once");
        #[cfg(target_os = "linux")]
        assert_eq!(watch_threads(), 1);
    }

    /// A task whose lock file is gone ends at once, on the caller's thread.
    #[test]
    fn bg_watch_of_a_missing_lock_ends_at_once() {
        let dir = cmux_unix_socket::short_test_dir("bg-watch-missing");
        let fired = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let f = fired.clone();
        watcher().watch(
            dir.path().join("gone.lock"),
            0xb9_0002,
            "s".into(),
            || true,
            move || {
                f.store(true, Ordering::SeqCst);
            },
        );
        assert!(fired.load(Ordering::SeqCst));
    }

    /// A hub with idle chat `name` (it ran turns before; no agent), on the coordinator list
    /// when `listed`.
    async fn hub_with_chat(name: &str, listed: bool) -> (Arc<Hub>, Arc<Session>) {
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        if listed {
            cfg.page_rule =
                Some(crate::config::PageRuleConfig { sessions: vec![format!("host/{name}")] });
        }
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": name, "name": name,
            "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
            "createdAt": 1, "updatedAt": 2});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        hub.begin_startup(false);
        let session = hub.resolve(name).unwrap();
        (hub, session)
    }

    /// An ended task of chat `session`, that exited with `code`.
    fn ended(id: &str, session: &Session, code: i32) -> Record {
        Record {
            id: id.into(),
            session_id: session.id.clone(),
            command: "make test".into(),
            ended_at: Some(2),
            exit_code: Some(code),
            notify: true,
            ..Record::default()
        }
    }

    /// In a chat on the coordinator list, an end with exit 0 starts no turn: it waits in the
    /// inbox, counts as sent, goes with the next notice, and a second send adds no second one.
    #[tokio::test]
    async fn a_listed_chats_exit_zero_end_waits_in_the_inbox() {
        let (hub, session) = hub_with_chat("coord-bg-ok", true).await;
        let dir = cmux_unix_socket::short_test_dir("bg-fold-ok");
        let record = ended("ok1", &session, 0);
        let writer = hub.config.write().await;
        tokio::time::timeout(
            std::time::Duration::from_secs(2),
            hub.bg_end_to_chat(&session, dir.path(), &record, None),
        )
        .await
        .expect("an exit notice reaches the inbox while configuration is being written");
        drop(writer);
        hub.bg_end_to_chat(&session, dir.path(), &record, None).await;
        assert!(bg_run::notified_path(dir.path(), "ok1").exists(), "sent: no restart owes it");
        {
            let inbox = session.inbox();
            assert_eq!(inbox.items.len(), 1, "once, however often it is sent");
            let item = &inbox.items[0];
            assert_eq!(item.prompt_id, "bg-done-ok1");
            assert!(!item.noticed, "no notice told the agent of it");
            assert!(
                item.text.contains("make test") && item.text.contains("exit 0"),
                "{}",
                item.text
            );
            assert!(inbox.in_flight.is_none() && inbox.refused_at == 0, "no turn was tried");
            assert!(inbox.timer.is_some(), "its flush is timed");
        }
        // It rides with the next turn the chat takes: a lane's block wakes it, the end is in
        // that notice.
        let block = Item::carried("b1", "lane-a", "blocked on #12");
        let mut block = block;
        block.noticed = false;
        block.class = PromptClass::Block;
        session.inbox().items.push(block);
        let inbox = session.inbox();
        let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
        assert!(super::super::inbox::render(&new).0.contains("exit 0"));
    }

    /// A failed end (nonzero exit, a signal) wakes the chat as before, listed or not: it is
    /// never left in the inbox.
    #[tokio::test]
    async fn a_listed_chats_failed_end_still_wakes() {
        let (hub, session) = hub_with_chat("coord-bg-failed", true).await;
        let dir = cmux_unix_socket::short_test_dir("bg-fold-failed");
        let mut killed = ended("k1", &session, 0);
        killed.exit_code = None;
        killed.signal = Some(9);
        for record in [ended("f1", &session, 2), killed] {
            hub.bg_end_to_chat(&session, dir.path(), &record, None).await;
        }
        assert!(session.inbox().items.is_empty(), "a failure is no inbox item: it is a prompt");
        for id in ["f1", "k1"] {
            // Held, it would be marked sent at once; a prompt is marked only when a turn takes
            // it, and this chat has no agent to take it.
            assert!(!bg_run::notified_path(dir.path(), id).exists(), "{id} took the prompt path");
        }
    }

    /// Which ends wait in the inbox: one that went well, in a listed chat or of an ended subagent.
    #[test]
    fn which_task_ends_are_held() {
        assert!(holds_end(true, true, false), "a coordinator's own exit 0");
        assert!(holds_end(true, false, true), "an ended subagent's exit 0, any chat");
        assert!(!holds_end(true, false, false), "the lead's own exit 0 in a plain chat wakes");
        assert!(!holds_end(false, true, true), "a failure always wakes");
        assert!(!holds_end(false, false, true));
    }

    /// In a chat not on the list, the exit-0 end of a task whose subagent ended starts no turn:
    /// it waits in the inbox, counts as sent, and names whose it was. Its failed end still wakes.
    #[tokio::test]
    async fn an_ended_subagents_exit_zero_end_waits_in_any_chat() {
        let (hub, session) = hub_with_chat("plain-bg-orphan", false).await;
        let dir = cmux_unix_socket::short_test_dir("bg-fold-orphan");
        let mut spool = bg_run::Spool::create(dir.path(), "o1", 1 << 20).unwrap();
        spool.write(b"3 passed\n").unwrap();
        let sub = json!({"id": "a9d84c88ffff", "type": "fork"});
        hub.bg_end_to_chat(&session, dir.path(), &ended("o1", &session, 0), Some(&sub)).await;
        assert!(bg_run::notified_path(dir.path(), "o1").exists(), "held: no restart owes it");
        {
            let inbox = session.inbox();
            assert_eq!(inbox.items.len(), 1);
            let item = &inbox.items[0];
            assert_eq!(item.prompt_id, "bg-done-o1");
            assert!(!item.noticed && inbox.in_flight.is_none(), "no turn was tried");
            assert!(item.text.contains("3 passed") && item.text.contains("fork subagent a9d84c88"));
        }
        hub.bg_end_to_chat(&session, dir.path(), &ended("o2", &session, 1), Some(&sub)).await;
        assert_eq!(session.inbox().items.len(), 1, "a failed end is a prompt, not an inbox item");
        assert!(!bg_run::notified_path(dir.path(), "o2").exists(), "o2 took the prompt path");
    }

    /// Which ends wait, and how long: a coordinator's or an orphan's to its class's deadline,
    /// the lead's own exit 0 in an idle chat [`OWN_END_HOLD_MS`], a failure not at all.
    #[test]
    fn how_long_task_ends_wait() {
        assert_eq!(end_hold(true, true, false, true), Some(None));
        assert_eq!(end_hold(true, false, true, false), Some(None));
        assert_eq!(end_hold(true, false, false, true), Some(Some(OWN_END_HOLD_MS)));
        assert_eq!(end_hold(true, false, false, false), None, "a running turn may wait on it");
        assert_eq!(end_hold(false, false, false, true), None, "a failure always wakes");
        assert_eq!(end_hold(false, true, true, true), None);
    }

    /// A chat not on the list holds its own exit-0 end [`OWN_END_HOLD_MS`]: an inbox item due
    /// then, marked sent, no turn tried; a second end in that window joins it, one wake for both.
    #[tokio::test]
    async fn an_unlisted_chats_exit_zero_end_waits_briefly() {
        let (hub, session) = hub_with_chat("plain-bg-ok", false).await;
        let dir = cmux_unix_socket::short_test_dir("bg-fold-unlisted");
        hub.bg_end_to_chat(&session, dir.path(), &ended("u1", &session, 0), None).await;
        hub.bg_end_to_chat(&session, dir.path(), &ended("u2", &session, 0), None).await;
        for id in ["u1", "u2"] {
            assert!(bg_run::notified_path(dir.path(), id).exists(), "{id} held, so marked sent");
        }
        let inbox = session.inbox();
        assert_eq!(inbox.items.len(), 2);
        for item in &inbox.items {
            assert_eq!(item.within, Some(OWN_END_HOLD_MS));
            assert_eq!(item.due(), item.at + OWN_END_HOLD_MS, "due in 5 minutes, not 15");
        }
        assert!(inbox.in_flight.is_none() && inbox.refused_at == 0, "no turn was tried yet");
        assert!(inbox.timer.is_some(), "its wake is timed");
    }

    /// Its failed end is still a prompt, at once.
    #[tokio::test]
    async fn an_unlisted_chats_failed_end_is_unchanged() {
        let (hub, session) = hub_with_chat("plain-bg-bad", false).await;
        let dir = cmux_unix_socket::short_test_dir("bg-fold-unlisted-bad");
        hub.bg_end_to_chat(&session, dir.path(), &ended("u3", &session, 1), None).await;
        assert!(session.inbox().items.is_empty());
        assert!(!bg_run::notified_path(dir.path(), "u3").exists(), "it took the prompt path");
    }
}

/// `cargo test -p acpmux --lib bg_watch_idle_bench -- --ignored --nocapture`: with 50 background
/// tasks running, the watcher thread's context switches over 10 idle seconds, then the delay
/// from each task's end (its lock let go) to its end firing. Touches only `watcher().watch`, so
/// the same bench runs on a tree without the close watch.
#[cfg(all(test, target_os = "linux"))]
mod idle_bench {
    use super::*;
    use std::time::{Duration, Instant};

    fn watch_thread_switches() -> u64 {
        let task = std::fs::read_dir("/proc/self/task")
            .unwrap()
            .flatten()
            .find(|t| {
                std::fs::read_to_string(t.path().join("comm"))
                    .is_ok_and(|c| c.trim() == "acpmux-bg-watch")
            })
            .expect("the watcher thread runs");
        std::fs::read_to_string(task.path().join("status"))
            .unwrap()
            .lines()
            .filter(|l| l.contains("ctxt_switches:"))
            .filter_map(|l| l.split_whitespace().nth(1)?.parse::<u64>().ok())
            .sum()
    }

    #[test]
    #[ignore = "bench: run alone with --ignored --nocapture"]
    fn bg_watch_idle_bench() {
        let dir = cmux_unix_socket::short_test_dir("bg-bench");
        let (tx, rx) = std::sync::mpsc::channel::<Instant>();
        let mut held = Vec::new();
        for i in 0..50 {
            let path = dir.path().join(format!("b{i}.lock"));
            let file = crate::home_fs::create_file(&path).unwrap();
            held.push(
                cmux_file_lock::FileLock::try_take(file, cmux_file_lock::Kind::Exclusive).unwrap(),
            );
            let tx = tx.clone();
            watcher().watch(
                path,
                0xbe_0001,
                "bench".into(),
                || true,
                move || {
                    let _ = tx.send(Instant::now());
                },
            );
        }
        std::thread::sleep(Duration::from_secs(2));
        let before = watch_thread_switches();
        std::thread::sleep(Duration::from_secs(10));
        let wakes = watch_thread_switches() - before;
        let mut delays = Vec::new();
        for lock in held.drain(..).take(30) {
            let let_go = Instant::now();
            drop(lock);
            let fired = rx.recv_timeout(Duration::from_secs(60)).expect("its end fired");
            delays.push(fired.duration_since(let_go).as_secs_f64() * 1000.0);
            // Apart from the tick, so each delay is its own.
            std::thread::sleep(Duration::from_millis(137));
        }
        delays.sort_by(f64::total_cmp);
        println!(
            "BENCH bg_watch idle_switches_10s={wakes} end_delay_ms p50={:.3} p90={:.3} max={:.3}",
            delays[delays.len() / 2],
            delays[delays.len() * 9 / 10],
            delays[delays.len() - 1]
        );
    }
}
