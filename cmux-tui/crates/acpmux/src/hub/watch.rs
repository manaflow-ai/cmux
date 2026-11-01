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
//! - A watched chat takes no prompt (`watch.read_only`). Its summary carries `watching`, so a
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
use std::time::Duration;

#[cfg(test)]
#[path = "watch_seed_tests.rs"]
mod seed_tests;

/// How often a watched transcript is checked for new lines.
const POLL: Duration = Duration::from_millis(400);

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

impl Hub {
    /// Makes a just-created adopted `session` watch `file` instead of running the conversation.
    pub(super) fn begin_watch(
        self: &Arc<Self>,
        session: &Arc<Session>,
        family: &str,
        file: std::path::PathBuf,
    ) -> Arc<Session> {
        let watching =
            Watching { family: family.to_owned(), file, offset: 0, codex_items: false, open: None };
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
            // Do not start copying the transcript before its older-history
            // boundary is safely journaled and checkpointed. Retry a transient
            // append, fsync, or metadata error while this is still a watch.
            loop {
                if hub.seek_watch_to_page(&session).await {
                    break;
                }
                if session.meta().watching.is_none()
                    || session.purged.load(std::sync::atomic::Ordering::SeqCst)
                    || session.status() == SessionStatus::Closed
                {
                    return;
                }
                tokio::time::sleep(POLL).await;
            }
            loop {
                let Some(watching) = session.meta().watching else { return };
                if session.status() == SessionStatus::Closed {
                    return;
                }
                let file = watching.file.clone();
                let read =
                    tokio::task::spawn_blocking(move || read_lines(&file, watching.offset)).await;
                let (lines, offset) = match read {
                    Ok(Ok(read)) => read,
                    // Gone or unreadable for now (the app rotates or rewrites it): try again.
                    _ => (Vec::new(), watching.offset),
                };
                // Even an oversized skipped chunk is progress; drain the backlog without a poll delay.
                let more = offset > watching.offset;
                if offset != watching.offset {
                    hub.show_watched(&session, &lines, offset).await;
                }
                if !more {
                    tokio::time::sleep(POLL).await;
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
        let scanned = tokio::task::spawn_blocking(move || -> std::io::Result<(u64, Option<String>)> {
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
    /// chat was taken over meanwhile.
    async fn show_watched(&self, session: &Session, lines: &[String], offset: u64) {
        // This journal is also written by a live turn. Keep the entire watched
        // batch, its checkpoint and the takeover transition in one order.
        let _turn = session.turn_lock.lock().await;
        if session.purged.load(std::sync::atomic::Ordering::SeqCst)
            || session.status() == SessionStatus::Closed
        {
            return;
        }
        let Some(mut watching) = session.meta().watching else { return };
        let open = &mut watching.open;
        let agent_sid = session.meta().agent_session_id.unwrap_or_default();
        for line in lines {
            let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
            let at = record_time(&record);
            for step in record_steps(&watching.family, &record, &mut watching.codex_items) {
                match step {
                    Step::Prompt(text) => {
                        if let Some(turn) = open.take() {
                            self.end_watched_turn(session, &turn, at);
                        }
                        *open = Some(self.begin_watched_turn(session, &text, at));
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
            if ends_turn(&watching.family, &record)
                && let Some(turn) = open.take()
            {
                self.end_watched_turn(session, &turn, at);
            }
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
                return;
            }
            m.watching = Some(watching);
        }
        self.save_meta(session);
    }

    /// The records a turn starts with, for a prompt the original app sent.
    fn begin_watched_turn(&self, session: &Session, text: &str, at: Option<u64>) -> WatchedTurn {
        let turn_id = format!("watched-{}", uuid::Uuid::now_v7());
        let prompt_id = format!("{turn_id}-prompt");
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
        let started = json!({"prompt": preview, "client": "watch", "promptId": prompt_id, "turnId": turn_id, "control": "local"});
        let turn_seq = self.append_at(session, "mux", "turn_started", started, None, at).0.seq;
        let msg =
            json!({"text": text, "client": "watch", "promptId": prompt_id, "turnId": turn_id});
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
