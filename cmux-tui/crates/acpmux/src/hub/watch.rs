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

/// Whether `record` says a Stop cut the running turn: Claude Code's `[Request interrupted by
/// user…]` line, Codex's `turn_aborted`.
fn interrupted(family: &str, record: &Value) -> bool {
    match family {
        "codex" => {
            record.get("type").and_then(Value::as_str) == Some("event_msg")
                && record.pointer("/payload/type").and_then(Value::as_str) == Some("turn_aborted")
        }
        _ => {
            record.get("type").and_then(Value::as_str) == Some("user")
                && record.get("isSidechain").and_then(Value::as_bool) != Some(true)
                && record
                    .pointer("/message/content")
                    .and_then(crate::adopt_replay::text_of)
                    .is_some_and(|t| t.starts_with("[Request interrupted by user"))
        }
    }
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
    /// person typed it (`origin.kind`; no origin reads as typed), `person` whether its origin
    /// says so (`human`).
    Absorbed { text: String, source: Option<String>, human: bool, person: bool },
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
            let kind = a.pointer("/origin/kind").and_then(Value::as_str);
            let human = kind.is_none_or(|k| k == "human");
            let person = kind == Some("human");
            Some(Queue::Absorbed { text: text(a.get("prompt"))?, source, human, person })
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
        // A restored chat whose app the registry names reads disconnected once it exits, or at
        // once when it exited while the daemon was down (`app_exit.rs`).
        self.follow_app(session, None);
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
        // An unindexed kind: the whole log, off the runtime's workers (`qos::off_worker`).
        let scanned = crate::qos::off_worker(|| {
            self.store.scan_kinds(&session.id, &["native_history"], &mut |event| {
                if event.dir == "mux"
                    && event.msg.get("before").and_then(Value::as_u64) == Some(start)
                    && event.msg.get("mark").and_then(Value::as_str) == Some(mark.as_str())
                {
                    recorded = true;
                    false
                } else {
                    true
                }
            })
        });
        if let Err(error) = scanned {
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
    async fn show_watched(
        self: &Arc<Self>,
        session: &Arc<Session>,
        lines: &[String],
        offset: u64,
    ) -> bool {
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
        // The terminal's queue is read only with Write to a Chat a Terminal Runs on: off, but
        // preserve queue/unshown state already captured while writable. Clearing it here would
        // make a prompt shown at enqueue appear a second time when its later user line arrives.
        let queue_read = self.terminal_chat_writable();
        let bridged = session.meta().tags.contains_key("bridge");
        for line in lines {
            let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
            let at = record_time(&record);
            // What the terminal queued while a turn ran shows the moment it is typed, once.
            if queue_read
                && watching.family == "claude"
                && let Some(queue) = queue_line(&record)
            {
                match queue {
                    Queue::Enqueued(text) => {
                        // Claude Code's own queue lines (a task notification) are no one's prompt.
                        if !crate::adopt_replay::queued_by_person(&text) {
                            continue;
                        }
                        // It may be a chat send's own queue line: it shows when it runs, by its
                        // attachment or its line, under the right id (`may_be_delivery`).
                        if !super::bridge::may_be_delivery(&session.id, &text)
                            && watching.queued.len() < MAX_QUEUED
                        {
                            if let Some(turn) = open.take() {
                                self.end_watched_turn(session, &turn, at);
                            }
                            *open = Some(self.begin_watched_turn(session, &text, at, None));
                            watching.queued.push(text);
                        } else {
                            // Shown when the turn takes it in, if no delivery claims it.
                            if watching.unshown.len() >= MAX_QUEUED {
                                watching.unshown.remove(0);
                            }
                            watching.unshown.push(text);
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
                    Queue::Absorbed { text, source, human, person } => {
                        let bridged = source
                            .as_deref()
                            .and_then(|uuid| super::bridge::delivered(&session.id, uuid))
                            .or_else(|| {
                                (!human)
                                    .then(|| super::bridge::delivered_queued(&session.id, &text))
                                    .flatten()
                            })
                            // Typed into the terminal by acpmux: the person's line, by its text.
                            .or_else(|| {
                                human
                                    .then(|| super::bridge::delivered_typed(&session.id, &text))
                                    .flatten()
                            });
                        let typed = bridged
                            .is_none()
                            .then(|| watching.queued.iter().position(|q| *q == text))
                            .flatten();
                        // Typed and not shown yet: its enqueue was past the cap or may have been a
                        // delivery's (`unshown`), or before the watch (its origin says `human`).
                        // Anything else (an inbox message, another session's, a coordinator's)
                        // is no prompt of the person's and shows as on base: not at all.
                        let held = (bridged.is_none() && typed.is_none())
                            .then(|| watching.unshown.iter().position(|q| *q == text))
                            .flatten();
                        if let Some(i) = held {
                            watching.unshown.remove(i);
                        }
                        if let Some(i) = typed {
                            // Shown when it was typed.
                            watching.queued.remove(i);
                        } else if bridged.is_some() || held.is_some() || person {
                            if let Some(turn) = open.take() {
                                self.end_watched_turn(session, &turn, at);
                            }
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
            // The app's own record of a request the provider refused ends its turn as failed,
            // never as the agent's answer (`bridge_hold.rs`).
            if let Some(error) = super::bridge::hold::api_error(&watching.family, &record) {
                let turn = open.take();
                // Held before the turn's call answers, so nothing sent after that answer goes
                // into the app before the reset.
                if bridged && super::bridge::hold::rate_limited(&record, &error) {
                    let turn_id = turn.as_ref().map(|t| t.turn_id.as_str());
                    self.bridge_rate_limited(session, turn_id, &error);
                }
                if let Some(turn) = &turn {
                    self.end_watched_turn_failed(session, turn, at, &error);
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
            // A Stop (Esc in the terminal, or the chat's Stop typed there) ends the turn it cut.
            if interrupted(&watching.family, &record) {
                if let Some(turn) = open.take() {
                    self.end_watched_turn_as(session, &turn, at, "cancelled");
                }
                continue;
            }
            let steps = record_steps(&watching.family, &record, &mut watching.codex_items);
            // A queued text that runs as no person's prompt (a scheduled wakeup's meta line, a
            // command echo) leaves the queue too: nothing else would take it out, and while it
            // waits every turn end reads as the previous turn's.
            if !watching.queued.is_empty()
                && !steps.iter().any(|s| matches!(s, Step::Prompt(_)))
                && record.get("type").and_then(Value::as_str) == Some("user")
                && let Some(text) =
                    record.pointer("/message/content").and_then(crate::adopt_replay::text_of)
                && let Some(i) = watching.queued.iter().position(|q| *q == text)
            {
                watching.queued.remove(i);
            }
            for step in steps {
                match step {
                    Step::Prompt(text) => {
                        // A prompt the terminal queued runs now: it shows already, as typed.
                        if let Some(i) = watching.unshown.iter().position(|q| *q == text) {
                            watching.unshown.remove(i);
                        }
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
                        // One acpmux typed into the terminal (`terminal_input.rs`) is the
                        // person's line: known by its text too.
                        let bridged = if watching.family == "codex" {
                            super::bridge::delivered_text(&session.id, &text)
                        } else {
                            super::bridge::delivered_typed(&session.id, &text)
                        };
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
        // A bridged prompt's tools note rides in the one text the app was sent; a daemon that
        // restarted before this line came no longer knows the delivery (`bridge.rs`
        // `delivered_text`), so its full text comes here: the transcript drops acpmux's own note
        // and keeps every other word (`tool_mentions::without_own_note`).
        // A matched delivery (`bridged`) already gives the person's visible text: nothing to strip,
        // so a copy of the note they typed themselves stays.
        let text = if bridged.is_some() {
            std::borrow::Cow::Borrowed(text)
        } else {
            crate::tool_mentions::without_own_note(text)
        };
        let text = text.as_ref();
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
        self.end_watched_turn_as(session, turn, at, "end_turn");
    }

    /// [`end_watched_turn`] with its stop reason (`cancelled` for a turn a Stop cut).
    fn end_watched_turn_as(
        &self,
        session: &Session,
        turn: &WatchedTurn,
        at: Option<u64>,
        stop_reason: &str,
    ) {
        let WatchedTurn { turn_id, prompt_id, turn_seq, .. } = turn;
        let end = json!({"stopReason": stop_reason, "turnId": turn_id, "turnSeq": turn_seq});
        self.append_at(session, "mux", "turn_end", end, None, at);
        let status = if stop_reason == "cancelled" { "cancelled" } else { "completed" };
        let result = json!({"status": status, "stopReason": stop_reason, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id});
        self.append_at(session, "mux", "turn_result", result, None, at);
        super::bridge::answered(&session.id, prompt_id, turn_id);
        // A turn that completed ends a rate-limit hold's doubling (`bridge_hold.rs`).
        super::bridge::hold::settled(&session.id);
    }

    /// The records a turn ends with when the app wrote an API error line for it (`error`).
    fn end_watched_turn_failed(
        &self,
        session: &Session,
        turn: &WatchedTurn,
        at: Option<u64>,
        error: &str,
    ) {
        let WatchedTurn { turn_id, prompt_id, turn_seq, .. } = turn;
        let end = json!({"stopReason": "end_turn", "turnId": turn_id, "turnSeq": turn_seq});
        self.append_at(session, "mux", "turn_end", end, None, at);
        let result = json!({"status": "failed", "error": error, "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id});
        self.append_at(session, "mux", "turn_result", result, None, at);
        // Delivered all the same: the app has the message, so it is never sent again.
        super::bridge::answered(&session.id, prompt_id, turn_id);
        // A prompt waiting to be typed into the terminal goes now (`terminal_input.rs`).
        super::terminal_input::turn_ended();
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
#[path = "watch_tests.rs"]
mod tests;
