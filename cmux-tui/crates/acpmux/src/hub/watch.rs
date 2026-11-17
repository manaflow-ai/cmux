//! Watching a Claude Code or Codex conversation without taking it over (Leo 2026-10-18: "see
//! the same session opened and viewed in cmux next without clobbering an existing claude/codex
//! session").
//!
//! `session/new` with `_meta.acpmux.adopt = {harness, agentSessionId, watch: true}` finds the
//! conversation's transcript as adopting does (`adopt.rs`), but starts no harness on it. acpmux
//! reads the transcript (Claude Code's `<id>.jsonl` under `projects/`, a Codex rollout) into
//! acpmux history, each prompt and answer as the records a live turn leaves, then keeps reading
//! what the original app appends. It only reads: nothing is written to the transcript or its
//! folder, and nothing locks it.
//!
//! - A prompt typed in the terminal while a turn runs shows at once: Claude Code writes a
//!   `queue-operation` line for it the moment it is queued, long before the turn takes it
//!   (`Queue`, `Watching::queued`).
//! - A watched chat takes no prompt (`watch.read_only`), unless its terminal or the desktop
//!   bridge takes it into the running app (`bridge.rs`). Its summary carries `watching`, so a
//!   client shows the composer off with a Take over action.
//! - `_acpmux/watch_take_over` ends the watch. While the original app still runs the
//!   conversation (`adopt_live.rs`) it is refused with `adopt.live` unless `ifLive` is `fork`
//!   (Claude Code: a new conversation branches off) or `open` (both apps on one conversation).
//!   The next prompt then starts the harness on the conversation as for any idle chat
//!   (`claude --resume`, Codex `session/load`); the history it shows is already there.
//! - The read position is saved with the session, so a watch goes on after a daemon restart
//!   where it stopped.
//! - A Claude Code transcript is shown from its newest page of turns (`adopt_replay_page.rs`); a
//!   Codex rollout over 64 MiB from its newest 64 MiB.

use super::{Hub, Session, SessionStatus};
use crate::adopt::IfLive;
use crate::adopt_replay::{Step, ends_turn, record_steps, record_time};
use crate::rpc::RpcError;
use crate::store::{WatchedTurn, Watching};
use serde_json::{Value, json};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::Arc;

#[cfg(test)]
#[path = "watch_seed_tests.rs"]
mod seed_tests;

#[path = "watch_tick.rs"]
mod tick;
pub(crate) use tick::WatchTicker;

#[cfg(test)]
#[path = "watch_idle_tests.rs"]
mod idle_tests;

/// Tests only: what the watches of this thread's runtime cost while transcripts are quiet: timer
/// wakeups, and hops to a blocking thread (`watch_idle_tests.rs`).
#[cfg(test)]
pub(super) mod idle_cost {
    thread_local! {
        static COST: std::cell::Cell<(u64, u64)> = const { std::cell::Cell::new((0, 0)) };
    }
    pub(crate) fn wakeup() {
        COST.with(|c| c.set((c.get().0 + 1, c.get().1)));
    }
    pub(crate) fn blocking() {
        COST.with(|c| c.set((c.get().0, c.get().1 + 1)));
    }
    /// (wakeups, blocking hops) since the last take.
    pub(crate) fn take() -> (u64, u64) {
        COST.with(|c| c.replace((0, 0)))
    }
}

/// A transcript bigger than this is read from its newest part only.
const MAX_BYTES: u64 = 64 << 20;

/// Most bytes one read takes, so a big backlog is shown in steps.
const MAX_READ: u64 = 4 << 20;

/// What a prompt, or a change to the queue, gets while the chat is watched.
pub(super) fn read_only() -> RpcError {
    RpcError::new(
        -32000,
        "watch.read_only: this chat shows a conversation another app runs; take it over to send",
    )
    .with_data(json!({"reason": "watch.read_only"}))
}

/// The complete lines of `file` from `offset` (at most [`MAX_READ`] bytes), and the offset after
/// the last complete one. A file shorter than `offset` was cut or replaced: it is followed from its
/// end, so nothing shown is shown twice. A first read of a big file starts at its newest
/// [`MAX_BYTES`], after a line break. A line longer than [`MAX_READ`] is skipped in
/// bounded chunks: each continuation checks the preceding byte before accepting a record.
pub(super) fn read_lines(file: &Path, offset: u64) -> std::io::Result<(Vec<String>, u64)> {
    read_lines_with_limits(file, offset, MAX_BYTES, MAX_READ)
}

// Same byte bounds as production; small ones make boundary tests inexpensive.
fn read_lines_with_limits(
    file: &Path,
    offset: u64,
    max_bytes: u64,
    max_read: u64,
) -> std::io::Result<(Vec<String>, u64)> {
    let mut f = std::fs::File::open(file)?;
    let len = f.metadata()?.len();
    let mut start = if offset > len { len } else { offset };
    if start == 0 && len > max_bytes {
        start = len - max_bytes;
    }
    if start >= len {
        return Ok((Vec::new(), start));
    }
    // An initial tail window or a prior overlong chunk can begin inside a JSONL
    // record. The byte before the cursor survives a restart and tells us whether
    // we are at a line boundary; no extra mutable or persisted skip flag is needed.
    let partial = if start == 0 {
        false
    } else {
        f.seek(SeekFrom::Start(start - 1))?;
        let mut previous = [0u8; 1];
        f.read_exact(&mut previous)?;
        previous[0] != b'\n'
    };
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::new();
    f.take(max_read.min(len - start)).read_to_end(&mut buf)?;
    let mut from = 0;
    if partial {
        match buf.iter().position(|&b| b == b'\n') {
            Some(i) => from = i + 1,
            // A giant record may cross several read windows. Advance by only
            // bytes actually read, then continue skipping until its newline.
            // The next read checks its preceding byte, so a fragment can never
            // masquerade as a complete record (also after daemon restart).
            None => return Ok((Vec::new(), start + buf.len() as u64)),
        }
    }
    // Only complete lines: the app may be halfway through writing the last one.
    let Some(end) = buf.iter().rposition(|&b| b == b'\n') else {
        let skip = if buf.len() as u64 == max_read { buf.len() as u64 } else { 0 };
        return Ok((Vec::new(), start + skip));
    };
    if end < from {
        return Ok((Vec::new(), start + from as u64));
    }
    let lines = String::from_utf8_lossy(&buf[from..end])
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(str::to_owned)
        .collect();
    Ok((lines, start + end as u64 + 1))
}

/// The prompt id and text of a delivered prompt `record` is the app's transcript line of: a
/// Claude Code `peer` user line with the uuid acpmux sent it with (`bridge.rs`).
fn bridged_line(
    family: &str,
    session_id: &str,
    record: &Value,
) -> Option<super::bridge::ShownDelivery> {
    if family != "claude"
        || record.get("type").and_then(Value::as_str) != Some("user")
        || record.pointer("/origin/kind").and_then(Value::as_str) != Some("peer")
    {
        return None;
    }
    super::bridge::delivered(session_id, record.get("uuid")?.as_str()?)
}

/// Most prompts kept as queued in the terminal (`Watching::queued`). Past it a prompt typed
/// mid-turn is not shown at once but when it runs (its attachment or its line), so the cap never
/// forgets a prompt that showed and never shows one twice.
const MAX_QUEUED: usize = 64;

/// What a Claude Code transcript line says of the prompts its terminal queued while a turn ran.
/// Claude Code 2.1 writes a `queue-operation` `enqueue` line with the text the moment a prompt is
/// typed mid-turn (measured: about 60 ms after Enter), then either takes it into the running turn
/// at its next tool boundary (an `attachment` of type `queued_command`, and a `remove` with reason
/// `absorbed_mid_turn`) or runs it after the turn (`dequeue`, then its `user` line).
#[derive(Debug, PartialEq)]
enum Queue {
    /// Typed while a turn ran: shown at once.
    Enqueued(String),
    /// Taken out of the queue: `absorbed` when the running turn took it (its attachment follows).
    Removed { text: String, absorbed: bool },
    /// Taken into the running turn; `source` is the uuid it was sent with, `human` whether the
    /// person typed it (`origin.kind`; no origin reads as typed).
    Absorbed { text: String, source: Option<String>, human: bool },
}

fn queue_line(record: &Value) -> Option<Queue> {
    // Trimmed as a prompt line's text is (`adopt_replay::text_of`), so the two compare equal.
    let text = |v: Option<&Value>| crate::adopt_replay::text_of(v?);
    match record.get("type").and_then(Value::as_str)? {
        "queue-operation" => {
            let content = text(record.get("content"))?;
            match record.get("operation").and_then(Value::as_str)? {
                "enqueue" => Some(Queue::Enqueued(content)),
                "remove" => Some(Queue::Removed {
                    text: content,
                    absorbed: record.get("reason").and_then(Value::as_str)
                        == Some("absorbed_mid_turn"),
                }),
                _ => None,
            }
        }
        "attachment" => {
            let a = record.get("attachment")?;
            if a.get("type").and_then(Value::as_str) != Some("queued_command")
                || a.get("commandMode").and_then(Value::as_str).is_some_and(|m| m != "prompt")
            {
                return None;
            }
            let source = a.get("source_uuid").and_then(Value::as_str).map(str::to_owned);
            let human =
                a.pointer("/origin/kind").and_then(Value::as_str).is_none_or(|k| k == "human");
            Some(Queue::Absorbed { text: text(a.get("prompt"))?, source, human })
        }
        _ => None,
    }
}

impl Hub {
    /// Makes a just-created adopted `session` watch `file` instead of running the conversation.
    pub(super) fn begin_watch(
        self: &Arc<Self>,
        session: &Arc<Session>,
        family: &str,
        file: std::path::PathBuf,
    ) -> Arc<Session> {
        let watching = Watching {
            family: family.to_owned(),
            file,
            offset: 0,
            codex_items: false,
            open: None,
            ..Default::default()
        };
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).watching = Some(watching);
        self.save_meta(session);
        self.append(session, "mux", "watch_started", json!({"family": family}));
        self.start_watch(session);
        session.clone()
    }

    /// Starts showing `session`'s watched transcript and following it (a new watch, or one a
    /// daemon restart found in the store).
    pub(super) fn start_watch(self: &Arc<Self>, session: &Arc<Session>) {
        if session.meta().watching.is_none() {
            return;
        }
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            // Woken by the hub's one check of all watched transcripts (`watch_tick.rs`) when
            // this one's length moved, never on a timer of its own.
            let check = hub.watch_ticker.register(&session);
            hub.follow_terminal(&session);
            let over = || {
                session.meta().watching.is_none()
                    || session.purged.load(std::sync::atomic::Ordering::SeqCst)
                    || session.status() == SessionStatus::Closed
            };
            // Do not start copying the transcript before its older-history
            // boundary is safely journaled and checkpointed. Retry a transient
            // append, fsync, or metadata error while this is still a watch.
            loop {
                if hub.seek_watch_to_page(&session).await {
                    break;
                }
                if over() {
                    return;
                }
                check.retry();
                check.wait().await;
            }
            loop {
                if over() {
                    return;
                }
                let Some(watching) = session.meta().watching else { return };
                let file = watching.file.clone();
                #[cfg(test)]
                idle_cost::blocking();
                let read =
                    tokio::task::spawn_blocking(move || read_lines(&file, watching.offset)).await;
                let (lines, offset) = match read {
                    Ok(Ok(read)) => read,
                    // Gone or unreadable for now (the app rotates or rewrites it): try again.
                    _ => {
                        check.retry();
                        (Vec::new(), watching.offset)
                    }
                };
                // Even an oversized skipped chunk is progress; drain the backlog without waiting.
                let mut more = offset > watching.offset;
                if offset != watching.offset && !hub.show_watched(&session, &lines, offset).await {
                    // Refused by the journal: the same batch, on the next check.
                    check.retry();
                    more = false;
                }
                if !more {
                    check.wait().await;
                    #[cfg(test)]
                    idle_cost::wakeup();
                }
            }
        });
    }

    /// A Claude Code watch that has read nothing yet starts at its transcript's newest page
    /// (`adopt_replay_page.rs`): the newest turns show at once, instead of the newest 64 MiB read
    /// oldest first. The older turns stay in the transcript, from the `native_history` record's
    /// `before` back.
    /// True when the initial history boundary is ready, or this is not a first
    /// Claude read. A write failure keeps the reader out of the older transcript
    /// until its seed has a durable journal marker (start_watch retries).
    async fn seek_watch_to_page(self: &Arc<Self>, session: &Arc<Session>) -> bool {
        let Some(watching) = session.meta().watching else { return true };
        if watching.offset != 0 || watching.family != "claude" {
            return true;
        }
        let file = watching.file.clone();
        // The newest page that starts at a prompt, so the first turn followed opens as a turn.
        let scanned =
            tokio::task::spawn_blocking(move || -> std::io::Result<(u64, Option<String>)> {
                // A missing/rotating source must retry the seed before the tail
                // reader starts. A valid source with no prompt in its scan window
                // still uses the original zero-offset fallback.
                let mut input = std::fs::File::open(&file)?;
                let start = crate::adopt_replay::newest_prompt_start_open(
                    &mut input,
                    crate::adopt_replay::PAGE_TURNS,
                )
                .unwrap_or(0);
                Ok((start, super::native_history::mark(&mut input, start)))
            })
            .await;
        let (start, mark) = match scanned {
            Ok(Ok(boundary)) => boundary,
            Ok(Err(error)) => {
                tracing::debug!(session = %session.id, "watched transcript not yet readable: {error}");
                return false;
            }
            Err(error) => {
                tracing::warn!(session = %session.id, "watched transcript seed scan failed: {error}");
                return false;
            }
        };
        if start == 0 {
            return true;
        }
        // A readable page boundary whose marker could not be computed must
        // wait for the source to become readable again.
        let Some(mark) = mark else { return false };
        self.commit_watch_page(session, start, mark).await
    }

    /// Publish the native-history seed ahead of its byte checkpoint. A failed
    /// append or fsync leaves the checkpoint at zero; a crash between a durable
    /// marker and metadata save retries the same marker only once.
    async fn commit_watch_page(
        self: &Arc<Self>,
        session: &Arc<Session>,
        start: u64,
        mark: String,
    ) -> bool {
        // The watched batch and Take Over use the same turn gate (#29181).
        let _turn = session.turn_lock.lock().await;
        if session.purged.load(std::sync::atomic::Ordering::SeqCst) {
            return false;
        }
        {
            let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if meta.status == SessionStatus::Closed
                || !meta.watching.as_ref().is_some_and(|w| w.offset == 0 && w.family == "claude")
            {
                return false;
            }
        }
        // A marker may have been written and synced before the prior process
        // died (or before a metadata write failed). Reuse its exact boundary
        // instead of inserting a second historical-page marker.
        let mut recorded = false;
        if let Err(error) = self.store.scan_kinds(&session.id, &["native_history"], &mut |event| {
            if event.dir == "mux"
                && event.msg.get("before").and_then(Value::as_u64) == Some(start)
                && event.msg.get("mark").and_then(Value::as_str) == Some(mark.as_str())
            {
                recorded = true;
                false
            } else {
                true
            }
        }) {
            tracing::warn!(session = %session.id, "read native history seed failed: {error}");
            return false;
        }
        if !recorded
            && !self.append_stored(
                session,
                "mux",
                "native_history",
                json!({"family": "claude", "before": start, "mark": mark}),
            )
        {
            return false;
        }
        // Journal append only guarantees a write, not a disk sync. Hold the
        // takeover gate while syncing the log and its directories, off runtime
        // workers: session.json may name this boundary only after that sync.
        let (hub, id) = (self.clone(), session.id.clone());
        match tokio::task::spawn_blocking(move || hub.store.flush_session(&id)).await {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                tracing::warn!(session = %session.id, "sync native history seed failed: {error}");
                return false;
            }
            Err(error) => {
                tracing::warn!(session = %session.id, "join native history seed sync failed: {error}");
                return false;
            }
        }
        {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            match meta.watching.as_mut() {
                Some(w) if w.offset == 0 => w.offset = start,
                _ => return false,
            }
        }
        self.save_meta(session);
        // save_meta logs and swallows a storage error. Check the persistent
        // checkpoint once here so a failed session.json write also retries.
        let saved = self
            .store
            .load(&session.id)
            .ok()
            .flatten()
            .is_some_and(|meta| meta.watching.as_ref().is_some_and(|w| w.offset == start));
        if !saved {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(w) = meta.watching.as_mut()
                && w.offset == start
            {
                w.offset = 0;
            }
        }
        saved
    }

    /// Appends what `lines` add as history and moves the read position to `offset`, unless the
    /// chat was taken over meanwhile. False when the journal refused one of the batch's records
    /// (it is neither stored nor heard, `append_record_locked`): the read position and the open
    /// turn stay where they were, so the batch is read again on the next check rather than lost.
    /// Its records stored before the refusal show again then; a duplicate beats a lost turn.
    async fn show_watched(&self, session: &Session, lines: &[String], offset: u64) -> bool {
        // This journal is also written by a live turn. Keep the entire watched
        // batch, its checkpoint and the takeover transition in one order.
        let _turn = session.turn_lock.lock().await;
        if session.purged.load(std::sync::atomic::Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
        {
            return true;
        }
        let Some(mut watching) = session.meta().watching else { return true };
        let refused = session.append_errors.load(std::sync::atomic::Ordering::SeqCst);
        let open = &mut watching.open;
        let agent_sid = session.meta().agent_session_id.unwrap_or_default();
        // What this batch takes from the delivery registry: given back if the journal refuses it.
        let mut claims = Vec::new();
        for line in lines {
            let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
            let at = record_time(&record);
            // What the terminal queued while a turn ran shows the moment it is typed, once.
            if watching.family == "claude"
                && let Some(queue) = queue_line(&record)
            {
                match queue {
                    Queue::Enqueued(text) => {
                        // It may be a chat send's own queue line: it shows when it runs, by its
                        // attachment or its line, under the right id (`may_be_delivery`).
                        // Claude Code's own queue lines (a task notification) are no one's prompt.
                        if !super::bridge::may_be_delivery(&session.id, &text)
                            && crate::adopt_replay::queued_by_person(&text)
                            && watching.queued.len() < MAX_QUEUED
                        {
                            if let Some(turn) = open.take() {
                                self.end_watched_turn(session, &turn, at);
                            }
                            *open = Some(self.begin_watched_turn(session, &text, at, None));
                            watching.queued.push(text);
                        }
                    }
                    // Taken back (edited, cancelled): it will not run as queued.
                    Queue::Removed { text, absorbed: false } => {
                        if let Some(i) = watching.queued.iter().position(|q| *q == text) {
                            watching.queued.remove(i);
                            // The open turn is the newest queued prompt's: it never runs.
                            if i == watching.queued.len()
                                && let Some(turn) = open.take()
                            {
                                self.end_watched_turn(session, &turn, at);
                            }
                        } else {
                            // A chat send's: its sender hears at once.
                            super::bridge::taken_back(&session.id, &text);
                        }
                    }
                    Queue::Removed { absorbed: true, .. } => {}
                    Queue::Absorbed { text, source, human } => {
                        let bridged = source
                            .as_deref()
                            .and_then(|uuid| super::bridge::delivered(&session.id, uuid))
                            .or_else(|| {
                                (!human)
                                    .then(|| super::bridge::delivered_queued(&session.id, &text))
                                    .flatten()
                            });
                        let typed = bridged
                            .is_none()
                            .then(|| watching.queued.iter().position(|q| *q == text))
                            .flatten();
                        if let Some(i) = typed {
                            // Shown when it was typed.
                            watching.queued.remove(i);
                        } else {
                            if let Some(turn) = open.take() {
                                self.end_watched_turn(session, &turn, at);
                            }
                            // A delivery under its id; else typed and not shown yet (its enqueue
                            // was before the watch, past the cap, or may have been a delivery's).
                            let prompt = match bridged {
                                Some((uuid, prompt_id, sent)) => {
                                    claims.push(super::bridge::Claim::Shown(uuid));
                                    self.begin_watched_turn(session, &sent, at, Some(prompt_id))
                                }
                                None => self.begin_watched_turn(session, &text, at, None),
                            };
                            *open = Some(prompt);
                        }
                    }
                }
                continue;
            }
            // A prompt acpmux delivered into the app (`bridge.rs`) shows as sent, under its id.
            if let Some((uuid, prompt_id, text)) =
                bridged_line(&watching.family, &session.id, &record)
            {
                claims.push(super::bridge::Claim::Shown(uuid));
                if let Some(turn) = open.take() {
                    self.end_watched_turn(session, &turn, at);
                }
                *open = Some(self.begin_watched_turn(session, &text, at, Some(prompt_id)));
                continue;
            }
            for step in record_steps(&watching.family, &record, &mut watching.codex_items) {
                match step {
                    Step::Prompt(text) => {
                        // A prompt the terminal queued runs now: it shows already, as typed.
                        if let Some(i) = watching.queued.iter().position(|q| *q == text) {
                            watching.queued.remove(i);
                            continue;
                        }
                        // A prompt that was never queued starts only once the queue is empty:
                        // what is left there was taken back.
                        watching.queued.clear();
                        if let Some(turn) = open.take() {
                            self.end_watched_turn(session, &turn, at);
                        }
                        // A prompt acpmux queued into the Codex thread (`bridge.rs`) shows as
                        // sent, under its id: its rollout line is known by its text alone.
                        let bridged = (watching.family == "codex")
                            .then(|| super::bridge::delivered_text(&session.id, &text))
                            .flatten();
                        let (text, prompt_id) = match bridged {
                            Some((uuid, prompt_id, sent)) => {
                                claims.push(super::bridge::Claim::Shown(uuid));
                                (sent, Some(prompt_id))
                            }
                            None => (text, None),
                        };
                        *open = Some(self.begin_watched_turn(session, &text, at, prompt_id));
                    }
                    Step::Answer(mut text) => {
                        // The pieces of one answer (text around a tool call) read as paragraphs.
                        if let Some(turn) = open.as_mut() {
                            if turn.answered {
                                text.insert_str(0, "\n\n");
                            }
                            turn.answered = true;
                        }
                        let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": agent_sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}});
                        self.append_at(session, "in", "agent_message_chunk", update, None, at);
                    }
                    Step::Tool(_) | Step::ToolResult(_) => {}
                }
            }
            // The turn a queued prompt is shown in has not begun while it waits: an end then is
            // the end of the turn before it.
            if ends_turn(&watching.family, &record)
                && watching.queued.is_empty()
                && let Some(turn) = open.take()
            {
                self.end_watched_turn(session, &turn, at);
            }
        }
        if session.append_errors.load(std::sync::atomic::Ordering::SeqCst) != refused {
            tracing::warn!(session = %session.id, "the journal refused a watched record: its batch is read again");
            super::bridge::unclaim(&claims);
            return false;
        }
        watching.offset = offset;
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            // Taken over meanwhile, or closed or purged: nothing is written back. `m.status`, not
            // `session.status()`: that takes this same lock again and would hang the runtime.
            if m.watching.is_none()
                || session.purged.load(std::sync::atomic::Ordering::SeqCst)
                || m.status == SessionStatus::Closed
            {
                return true;
            }
            m.watching = Some(watching);
        }
        self.save_meta(session);
        true
    }

    /// The records a turn starts with, for a prompt the original app sent.
    /// `bridged`: the id of the prompt acpmux delivered (`bridge.rs`), which this turn answers.
    fn begin_watched_turn(
        &self,
        session: &Session,
        text: &str,
        at: Option<u64>,
        bridged: Option<String>,
    ) -> WatchedTurn {
        let turn_id = format!("watched-{}", uuid::Uuid::now_v7());
        let client = if bridged.is_some() { "bridge" } else { "watch" };
        let prompt_id = bridged.unwrap_or_else(|| format!("{turn_id}-prompt"));
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if m.title.is_none()
                && let Some(first) = text.lines().find(|l| !l.trim().is_empty())
            {
                m.title = Some(super::short_text(first.trim(), 80));
            }
            m.last_prompt = Some(super::short_text(text, 200));
            m.turn_count += 1;
        }
        let preview: String = text.chars().take(200).collect();
        let started = json!({"prompt": preview, "client": client, "promptId": prompt_id, "turnId": turn_id, "control": "local"});
        let turn_seq = self.append_at(session, "mux", "turn_started", started, None, at).0.seq;
        let msg = json!({"text": text, "client": client, "promptId": prompt_id, "turnId": turn_id});
        self.append_at(session, "mux", "user_message", msg, None, at);
        WatchedTurn { turn_id, prompt_id, turn_seq, answered: false }
    }

    /// The records a turn ends with, once the transcript says it ended or the next prompt came.
    fn end_watched_turn(&self, session: &Session, turn: &WatchedTurn, at: Option<u64>) {
        let WatchedTurn { turn_id, prompt_id, turn_seq, .. } = turn;
        let end = json!({"stopReason": "end_turn", "turnId": turn_id, "turnSeq": turn_seq});
        self.append_at(session, "mux", "turn_end", end, None, at);
        let result = json!({"status": "completed", "stopReason": "end_turn", "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id});
        self.append_at(session, "mux", "turn_result", result, None, at);
        super::bridge::answered(&session.id, prompt_id, turn_id);
    }

    /// `_acpmux/watch_take_over`: ends the watch so the chat runs the conversation itself.
    /// Refused with `adopt.live` while the original app still runs it, unless `if_live` forks it
    /// (Claude Code) or opens it anyway.
    pub async fn watch_take_over(
        &self,
        session: &Arc<Session>,
        if_live: IfLive,
    ) -> Result<Value, RpcError> {
        let Some(watching) = session.meta().watching else {
            return Err(RpcError::invalid_params("this chat is not watching a conversation"));
        };
        let family = watching.family.clone();
        let Some(id) = session.meta().agent_session_id else {
            return Err(RpcError::internal("a watched chat has no conversation id"));
        };
        if if_live == IfLive::Fork && family != "claude" {
            return Err(RpcError::invalid_params(format!(
                "only Claude Code chats fork; open this {family} chat anyway or close it where it runs"
            )));
        }
        if if_live == IfLive::Refuse {
            // The holder the harness records in the store that holds the chat, as an adopt
            // checks it (`hub/adoption.rs`); one that has exited does not count.
            // The harness's env (profile, preset, the chat's own store), as fork and aside read it:
            // a store a profile sets is where the original app records its holder.
            let meta = session.meta();
            let (_, env) = self.harness_env(&meta).await;
            let homes = self.harness_homes().with_env(&[&env]);
            let root = meta.chat_store.clone().unwrap_or_else(|| match family.as_str() {
                "codex" => homes.codex.clone(),
                _ => homes.claude.clone(),
            });
            let (fam, sid) = (family.clone(), id.clone());
            let live =
                tokio::task::spawn_blocking(move || crate::adopt_live::holder(&fam, &sid, &root))
                    .await
                    .map_err(|e| RpcError::internal(e.to_string()))?;
            if let Some(live) = live {
                return Err(RpcError::invalid_params(live.refusal(&family, &id))
                    .with_data(json!({"reason": "adopt.live", "details": live.details(&family)})));
            }
        }
        // A file read can finish at the same time as Take Over. Wait for its
        // complete journal append and checkpoint before removing watch ownership;
        // hold the gate through watch_taken_over so later tails see no watch.
        let _turn = session.turn_lock.lock().await;
        if session.meta().watching.is_none() {
            return Err(RpcError::invalid_params("this chat is no longer watching a conversation"));
        }
        let fork = if_live == IfLive::Fork;
        let open = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let open = m.watching.take().and_then(|w| w.open);
            // A fork resumes nothing as itself: its first spawn branches the conversation off.
            if fork {
                m.set_agent_session_id(None, &family);
            }
            open
        };
        // The other app's open turn is settled here: this chat's own turns follow.
        if let Some(turn) = open {
            self.end_watched_turn(session, &turn, None);
        }
        if fork {
            *session.fork_from.lock().unwrap_or_else(|e| e.into_inner()) = Some(id.clone());
        }
        self.save_meta(session);
        // No terminal drives a chat that runs its conversation itself.
        self.unmark_terminal_driven(session);
        // Watchers hear it as `_acpmux/session_changed`, with the summary that has no `watching`.
        self.append(
            session,
            "mux",
            "watch_taken_over",
            json!({"agentSessionId": id, "fork": fork}),
        );
        Ok(self.session_summary(session))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// The session's turn gate also fences the transition from following an outside transcript
    /// to accepting a live harness. A takeover must wait while a watched tail is committing.
    #[tokio::test]
    async fn takeover_waits_for_the_watched_tail_gate() {
        use crate::config::{Config, StoreMode};

        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let session = hub
            .new_session(crate::hub::NewRequest {
                cwd: Some(std::env::temp_dir()),
                ..Default::default()
            })
            .await
            .unwrap();
        {
            let mut meta = session.meta.lock().unwrap();
            meta.agent_session_id = Some("outside-session".to_owned());
            meta.watching = Some(Watching {
                family: "claude".to_owned(),
                file: std::env::temp_dir().join("watched-outside-session.jsonl"),
                offset: 0,
                codex_items: false,
                open: None,
                ..Default::default()
            });
        }

        // A tail holding this gate is still entitled to commit its watched events. The
        // takeover must wait, then close the watch and publish the handoff in that order.
        let tail_guard = session.turn_lock.lock().await;
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let taking = tokio::spawn({
            let (hub, session) = (hub.clone(), session.clone());
            async move {
                let _ = ready_tx.send(());
                hub.watch_take_over(&session, IfLive::Open).await
            }
        });
        ready_rx.await.unwrap();
        tokio::task::yield_now().await;
        assert!(!taking.is_finished(), "takeover raced a watched tail into the journal");
        assert!(
            session.meta().watching.is_some(),
            "the view-only owner changed before the tail finished"
        );

        drop(tail_guard);
        taking.await.unwrap().unwrap();
        assert!(session.meta().watching.is_none());

        // A file read can finish before Take Over and be scheduled afterward.
        // Exercise that stale completion deterministically: the old reader
        // must neither create a watched turn nor append any record to the live
        // conversation's journal.
        let before = session.meta().event_count;
        let late_line =
            json!({"type": "user", "message": {"content": "late watched prompt"}}).to_string();
        hub.show_watched(&session, &[late_line], 128).await;
        assert_eq!(session.meta().turn_count, 0, "a watched turn was appended after Take Over");
        assert_eq!(session.meta().event_count, before, "the stale reader wrote after Take Over");
        assert!(
            hub.watch_take_over(&session, IfLive::Open).await.is_err(),
            "Take Over succeeded twice"
        );
        hub.shutdown_all().await;
    }

    /// A watched batch whose record the journal refused (neither stored nor heard) keeps its read
    /// position, so the next check reads it again; it used to move on and lose the turn.
    #[tokio::test(flavor = "current_thread")]
    async fn a_watched_batch_the_journal_refused_is_read_again() {
        use crate::config::{Config, StoreMode};
        use crate::store::REFUSE_APPENDS;

        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let session = hub
            .new_session(crate::hub::NewRequest {
                cwd: Some(std::env::temp_dir()),
                ..Default::default()
            })
            .await
            .unwrap();
        {
            let mut meta = session.meta.lock().unwrap();
            meta.agent_session_id = Some("outside-session".to_owned());
            meta.watching = Some(Watching {
                family: "claude".to_owned(),
                file: std::env::temp_dir().join("watched-refused-session.jsonl"),
                offset: 0,
                codex_items: false,
                open: None,
                ..Default::default()
            });
        }
        let line = json!({"type": "user", "message": {"content": "watched prompt"}}).to_string();

        REFUSE_APPENDS.with(|r| r.set(true));
        let shown = hub.show_watched(&session, std::slice::from_ref(&line), 128).await;
        REFUSE_APPENDS.with(|r| r.set(false));
        assert!(!shown, "a refused batch reads as shown");
        let watching = session.meta().watching.unwrap();
        assert_eq!(watching.offset, 0, "the read position moved past a refused batch");
        assert!(watching.open.is_none(), "the refused batch's turn was kept open");

        assert!(hub.show_watched(&session, &[line], 128).await);
        assert_eq!(session.meta().watching.unwrap().offset, 128);
        let records = hub.events(&session.id, 0, 100).unwrap();
        assert!(
            records.iter().any(|e| e.kind == "user_message" && e.msg["text"] == "watched prompt"),
            "the batch read again was stored"
        );
        hub.shutdown_all().await;
    }

    /// A watched Claude chat in a hub of its own, for the queue and delivery tests below.
    async fn queue_hub(name: &str) -> (Arc<Hub>, Arc<Session>) {
        use crate::config::{Config, StoreMode};
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(config, store);
        let session = hub
            .new_session(crate::hub::NewRequest {
                cwd: Some(std::env::temp_dir()),
                ..Default::default()
            })
            .await
            .unwrap();
        {
            let mut meta = session.meta.lock().unwrap();
            meta.agent_session_id = Some(format!("outside-{name}"));
            meta.watching = Some(Watching {
                family: "claude".to_owned(),
                file: std::env::temp_dir().join(format!("watched-{name}.jsonl")),
                ..Default::default()
            });
        }
        (hub, session)
    }

    fn prompts_of(hub: &Hub, session: &Session) -> Vec<(String, String)> {
        hub.events(&session.id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "user_message")
            .map(|e| {
                let text = e.msg["text"].as_str().unwrap_or_default().to_owned();
                let client = e.msg["client"].as_str().unwrap_or_default().to_owned();
                (text, client)
            })
            .collect()
    }

    /// A delivery's line in a batch the journal refused shows when the batch is read again: the
    /// claim on it is given back (review P1-F2). It used to stay marked shown and never show.
    #[tokio::test(flavor = "current_thread")]
    async fn a_delivery_in_a_refused_batch_shows_when_the_batch_is_read_again() {
        use crate::store::REFUSE_APPENDS;
        let (hub, session) = queue_hub("refused-delivery").await;
        super::super::bridge::test_delivery(&session.id, "p-refused", "u-refused", "from the chat");
        let line = json!({"type": "user", "uuid": "u-refused", "origin": {"kind": "peer"},
            "message": {"content": "from the chat"}})
        .to_string();
        REFUSE_APPENDS.with(|r| r.set(true));
        let shown = hub.show_watched(&session, std::slice::from_ref(&line), 128).await;
        REFUSE_APPENDS.with(|r| r.set(false));
        assert!(!shown);
        assert!(hub.show_watched(&session, &[line], 128).await);
        assert_eq!(prompts_of(&hub, &session), [("from the chat".to_owned(), "bridge".to_owned())]);
        hub.shutdown_all().await;
    }

    /// Past the queued cap a prompt typed mid-turn shows when it runs, never twice and never lost
    /// (review P2-F4: the cap used to forget the oldest one shown, which then showed again).
    #[tokio::test(flavor = "current_thread")]
    async fn prompts_typed_past_the_queued_cap_each_show_once() {
        let (hub, session) = queue_hub("cap").await;
        let n = MAX_QUEUED + 3;
        let mut lines: Vec<String> = (0..n)
            .map(|i| {
                json!({"type": "queue-operation", "operation": "enqueue", "content": format!("typed {i}")})
                    .to_string()
            })
            .collect();
        for i in 0..n {
            lines.push(json!({"type": "queue-operation", "operation": "dequeue"}).to_string());
            lines.push(
                json!({"type": "user", "uuid": format!("t{i}"), "message": {"content": format!("typed {i}")}})
                    .to_string(),
            );
        }
        assert!(hub.show_watched(&session, &lines, 128).await);
        let shown: Vec<String> = prompts_of(&hub, &session).into_iter().map(|(t, _)| t).collect();
        let want: Vec<String> = (0..n).map(|i| format!("typed {i}")).collect();
        assert_eq!(shown, want, "each once, in order");
        hub.shutdown_all().await;
    }

    /// A terminal prompt whose text contains, or repeats, a pending chat delivery's still shows as
    /// typed, in either order of the two queue lines; the delivery shows once under its own id
    /// (review P1-F1, P2-F3). A cancelled delivery ends at once, and its row never shows.
    #[tokio::test(flavor = "current_thread")]
    async fn terminal_prompts_overlapping_a_delivery_still_show() {
        for typed_first in [false, true] {
            let (hub, session) = queue_hub(&format!("overlap-{typed_first}")).await;
            let delivery = format!("u-test-{typed_first}");
            super::super::bridge::test_delivery(&session.id, "p-test", &delivery, "test");
            let enqueue = |t: &str| {
                json!({"type": "queue-operation", "operation": "enqueue", "content": t}).to_string()
            };
            let absorbed = |t: &str, source: &str, kind: &str| {
                json!({"type": "attachment", "attachment": {"type": "queued_command", "prompt": t,
                    "source_uuid": source, "commandMode": "prompt", "origin": {"kind": kind}}})
                .to_string()
            };
            let typed = uuid::Uuid::now_v7().to_string();
            // The delivery's queue line and the same text typed in the terminal read the same: the
            // order is told only by which the turn takes in first, below.
            let lines_head =
                [enqueue("please test the migration"), enqueue("test"), enqueue("test")];
            let mut lines = lines_head.to_vec();
            let (first, second) = if typed_first {
                (absorbed("test", &typed, "human"), absorbed("test", &delivery, "peer"))
            } else {
                (absorbed("test", &delivery, "peer"), absorbed("test", &typed, "human"))
            };
            lines.push(absorbed("please test the migration", "x", "human"));
            lines.push(first);
            lines.push(second);
            assert!(hub.show_watched(&session, &lines, 128).await);
            let mut shown = prompts_of(&hub, &session);
            shown.sort();
            assert_eq!(
                shown,
                [
                    ("please test the migration".to_owned(), "watch".to_owned()),
                    ("test".to_owned(), "bridge".to_owned()),
                    ("test".to_owned(), "watch".to_owned()),
                ],
                "typed first: {typed_first}"
            );
            hub.shutdown_all().await;
        }
    }

    /// A prompt typed mid-turn with the same text as a chat send the app has not queued yet is the
    /// person's: it shows as typed when it runs, and the send stays pending for its own line (review
    /// P1-F1 of 94dffc97: the typed `enqueue` was taken as the send's, and the prompt shown as the
    /// send's, under its id).
    #[tokio::test(flavor = "current_thread")]
    async fn a_typed_prompt_with_a_pending_sends_text_shows_as_typed() {
        let (hub, session) = queue_hub("same-text-typed").await;
        super::super::bridge::test_delivery(&session.id, "p-same", "u-same", "test");
        let lines = vec![
            json!({"type": "queue-operation", "operation": "enqueue", "content": "test"})
                .to_string(),
            json!({"type": "attachment", "attachment": {"type": "queued_command", "prompt": "test",
                "source_uuid": "typed-cmd", "commandMode": "prompt", "origin": {"kind": "human"}}})
            .to_string(),
        ];
        assert!(hub.show_watched(&session, &lines, 128).await);
        assert_eq!(prompts_of(&hub, &session), [("test".to_owned(), "watch".to_owned())]);
        assert!(
            super::super::bridge::delivered(&session.id, "u-same").is_some(),
            "the send still waits"
        );
        hub.shutdown_all().await;
    }

    /// A queued prompt taken back in the terminal settles the turn shown for it, and a chat send
    /// taken back ends with why instead of waiting half an hour (review P1-F2, P2-F2 of 94dffc97).
    #[tokio::test(flavor = "current_thread")]
    async fn a_queued_prompt_taken_back_settles_and_a_taken_back_send_ends() {
        let (hub, session) = queue_hub("taken-back").await;
        let rx = {
            super::super::bridge::test_delivery(&session.id, "p-back", "u-back", "from the chat");
            super::super::bridge::delivery_turn(&session.id, "p-back").unwrap()
        };
        let op = |op: &str, t: &str| {
            json!({"type": "queue-operation", "operation": op, "content": t}).to_string()
        };
        let lines = vec![
            op("enqueue", "typed then cancelled"),
            op("remove", "typed then cancelled"),
            op("enqueue", "from the chat"),
            op("remove", "from the chat"),
        ];
        assert!(hub.show_watched(&session, &lines, 128).await);
        assert!(
            session.meta().watching.unwrap().open.is_none(),
            "the cancelled prompt's turn is settled"
        );
        assert!(matches!(&*rx.borrow(), Some(Err(why)) if why.contains("taken back")));
        let shown: Vec<String> = prompts_of(&hub, &session).into_iter().map(|(t, _)| t).collect();
        assert_eq!(shown, ["typed then cancelled"]);
        hub.shutdown_all().await;
    }

    #[test]
    fn only_complete_lines_are_read_and_the_offset_follows_them() {
        let dir = std::env::temp_dir().join(format!("acpmux-watch-lines-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("t.jsonl");
        std::fs::write(&file, "{\"a\":1}\n{\"b\":2}\n{\"c\":").unwrap();
        let (lines, offset) = read_lines(&file, 0).unwrap();
        assert_eq!(lines, ["{\"a\":1}", "{\"b\":2}"]);
        assert_eq!(offset, 16);
        let (lines, again) = read_lines(&file, offset).unwrap();
        assert!(lines.is_empty());
        assert_eq!(again, offset);
        std::fs::OpenOptions::new().append(true).open(&file).unwrap().write_all(b"3}\n").unwrap();
        let (lines, offset) = read_lines(&file, offset).unwrap();
        assert_eq!(lines, ["{\"c\":3}"]);
        assert_eq!(offset, 24);
        // A cut, shorter file is followed from its end: nothing is shown twice.
        std::fs::write(&file, "{\"d\":4}\n").unwrap();
        let (lines, offset) = read_lines(&file, offset).unwrap();
        assert!(lines.is_empty());
        std::fs::OpenOptions::new().append(true).open(&file).unwrap().write_all(b"{}\n").unwrap();
        assert_eq!(read_lines(&file, offset).unwrap().0, ["{}"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A first 64 MiB window may begin halfway through a very large JSONL entry.
    /// Once that entry ends, the reader must advance and reach the valid following row.
    #[test]
    fn oversized_first_window_line_advances_to_the_next_record() {
        let dir = std::env::temp_dir().join(format!("acpmux-watch-long-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("oversized.jsonl");
        let content = format!("{{\"large\":\"{}\"}}\n{{\"next\":true}}\n", "x".repeat(160));
        std::fs::write(&file, content.as_bytes()).unwrap();
        let window_start = content.len() as u64 - 64;

        // The old code found no newline in the first 20 bytes, returned window_start,
        // and repeated the same read forever with offset still zero.
        let (lines, after_large) = read_lines_with_limits(&file, 0, 64, 20).unwrap();
        assert!(lines.is_empty());
        assert!(after_large > window_start, "stalled at the overlong line");
        let (mut at, mut received) = (after_large, Vec::new());
        for _ in 0..12 {
            let (lines, next) = read_lines_with_limits(&file, at, 64, 20).unwrap();
            assert!(next > at);
            received.extend(lines);
            at = next;
            if at == content.len() as u64 {
                break;
            }
        }
        assert_eq!(received, ["{\"next\":true}"]);
        assert_eq!(at, content.len() as u64);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The source may still be writing its oversized first JSONL entry. Skip its
    /// unfinished chunks across polls, then deliver complete rows after its newline.
    #[test]
    fn oversized_incomplete_window_line_resumes_when_terminated() {
        let dir =
            std::env::temp_dir().join(format!("acpmux-watch-partial-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("partial.jsonl");
        let unfinished = format!("{{\"large\":\"{}", "x".repeat(160));
        std::fs::write(&file, unfinished.as_bytes()).unwrap();
        let mut at = 0;
        for _ in 0..12 {
            let (lines, next) = read_lines_with_limits(&file, at, 64, 20).unwrap();
            assert!(lines.is_empty());
            assert!(next > at);
            at = next;
            if at == unfinished.len() as u64 {
                break;
            }
        }
        assert_eq!(at, unfinished.len() as u64);
        // A larger source file continues the same unfinished line; the byte
        // before the saved checkpoint still identifies it as a partial line.
        std::fs::OpenOptions::new()
            .append(true)
            .open(&file)
            .unwrap()
            .write_all(b"\"}\n{\"next\":1}\n")
            .unwrap();
        let (lines, done) = read_lines_with_limits(&file, at, 64, 20).unwrap();
        assert_eq!(lines, ["{\"next\":1}"]);
        assert_eq!(done, unfinished.len() as u64 + b"\"}\n{\"next\":1}\n".len() as u64);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A normal watched file can also append one huge line that spans several
    /// chunks. Fragments of it must never appear as independent JSONL records.
    #[test]
    fn a_line_at_the_previous_checkpoint_skips_all_overlong_fragments() {
        let dir =
            std::env::temp_dir().join(format!("acpmux-watch-fragments-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("fragments.jsonl");
        let content = format!("{{\"large\":\"{}\"}}\n{{\"next\":2}}\n", "x".repeat(106));
        std::fs::write(&file, content.as_bytes()).unwrap();
        let (mut at, mut received) = (0, Vec::new());
        for _ in 0..12 {
            let (lines, next) = read_lines_with_limits(&file, at, 4096, 20).unwrap();
            assert!(next > at || at == content.len() as u64);
            received.extend(lines);
            at = next;
            if at == content.len() as u64 {
                break;
            }
        }
        assert_eq!(at, content.len() as u64);
        assert_eq!(received, ["{\"next\":2}"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
