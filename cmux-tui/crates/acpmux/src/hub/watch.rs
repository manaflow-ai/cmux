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
//! - A transcript over 64 MiB is read from its newest 64 MiB.

use super::{Hub, Session, SessionStatus};
use crate::adopt::IfLive;
use crate::adopt_replay::{Step, ends_turn, record_steps, record_time};
use crate::rpc::RpcError;
use crate::store::{WatchedTurn, Watching};
use serde_json::{Value, json};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::Arc;

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
/// [`MAX_BYTES`], after a line break. A line longer than [`MAX_READ`] is skipped: its rest fails
/// to parse and is dropped.
pub(super) fn read_lines(file: &Path, offset: u64) -> std::io::Result<(Vec<String>, u64)> {
    let mut f = cmux_blocking::fs::open(file)?;
    let len = f.metadata()?.len();
    let mut start = if offset > len { len } else { offset };
    let skip_partial = start == 0 && len > MAX_BYTES;
    if skip_partial {
        start = len - MAX_BYTES;
    }
    if start >= len {
        return Ok((Vec::new(), start));
    }
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::new();
    f.take(MAX_READ.min(len - start)).read_to_end(&mut buf)?;
    let mut from = 0;
    if skip_partial {
        match buf.iter().position(|&b| b == b'\n') {
            Some(i) => from = i + 1,
            None => return Ok((Vec::new(), start)),
        }
    }
    // Only complete lines: the app may be halfway through writing the last one.
    let Some(end) = buf.iter().rposition(|&b| b == b'\n') else {
        let skip = if buf.len() as u64 == MAX_READ { buf.len() as u64 } else { 0 };
        return Ok((Vec::new(), start + skip));
    };
    if end < from {
        return Ok((Vec::new(), start + from as u64));
    }
    let lines = String::from_utf8_lossy(buf.get(from..end).unwrap_or_default())
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(str::to_owned)
        .collect();
    Ok((lines, start + end as u64 + 1))
}

/// The watcher to keep alive while a transcript is followed, and its wakes.
type Changes = (notify::RecommendedWatcher, tokio::sync::mpsc::Receiver<()>);

/// A watch on `file`'s folder that sends once per batch of changes to `file`, and the watcher
/// to keep alive while it is read. None, logged, when the folder cannot be watched (it is gone,
/// or the system is out of watches): the chat shows what the transcript holds now and follows
/// it again at the next daemon start.
fn changes(file: &Path) -> Option<Changes> {
    use notify::Watcher;
    let (folder, name) = (file.parent()?.to_owned(), file.file_name()?.to_owned());
    // One pending wake is enough: each wake reads everything new.
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if event.is_ok_and(|e| changes_file(&e, &name)) {
            let _ = tx.try_send(());
        }
    })
    .map_err(
        |e| tracing::warn!(file = %file.display(), "a watched transcript cannot be followed: {e}"),
    )
    .ok()?;
    if let Err(e) = watcher.watch(&folder, notify::RecursiveMode::NonRecursive) {
        tracing::warn!(file = %file.display(), "a watched transcript cannot be followed: {e}");
        return None;
    }
    Some((watcher, rx))
}

/// Whether folder event `event` may have changed the file named `name`. An open, a read or a
/// close after reading is no change: Linux inotify reports them (`notify` watches `IN_OPEN`),
/// and the watch's own read would wake the next one. Chromium's FilePathWatcher watches only
/// changes (`base/files/file_path_watcher_inotify.cc`: no `IN_OPEN`, `IN_ACCESS`).
fn changes_file(event: &notify::Event, name: &std::ffi::OsStr) -> bool {
    use notify::event::{AccessKind, AccessMode, EventKind};
    let change = match event.kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
        EventKind::Access(_) => false,
        _ => true,
    };
    change && event.paths.iter().any(|p| p.file_name() == Some(name))
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
        self.follow_watch(session, changes);
    }

    /// [`Hub::start_watch`] with the folder watch `watch` makes (`changes`; a test's fails).
    /// The transcript is read once whether or not the watch was made.
    fn follow_watch(
        self: &Arc<Self>,
        session: &Arc<Session>,
        watch: impl FnOnce(&Path) -> Option<Changes> + Send + 'static,
    ) -> Option<tokio::task::JoinHandle<()>> {
        session.meta().watching.as_ref()?;
        let (hub, session) = (self.clone(), session.clone());
        Some(tokio::spawn(async move {
            // The transcript's folder, watched for a change to the file (the file itself may be
            // replaced or appear later): each change reads what the app appended. No change, no
            // wake (D6); it replaced a 400 ms poll of every watched chat. It is made before the
            // first read, so a change after that read wakes the next.
            let Some(watching) = session.meta().watching else { return };
            let mut changes = watch(&watching.file);
            loop {
                let Some(watching) = session.meta().watching else { return };
                if session.status() == SessionStatus::Closed {
                    return;
                }
                let file = watching.file.clone();
                let read =
                    crate::daemon::spawn_blocking(move || read_lines(&file, watching.offset)).await;
                let (lines, offset) = match read {
                    Ok(Ok(read)) => read,
                    // Gone or unreadable for now (the app rotates or rewrites it): try again.
                    _ => (Vec::new(), watching.offset),
                };
                let more = offset > watching.offset && !lines.is_empty();
                if offset != watching.offset {
                    hub.show_watched(&session, &lines, offset);
                }
                if more {
                    continue;
                }
                // No watch: what the transcript holds now is shown, and nothing follows it.
                let Some((_watcher, changed)) = changes.as_mut() else { return };
                tokio::select! {
                    change = changed.recv() => if change.is_none() { return },
                    // A take-over, a close or a purge: the loop's checks above end it.
                    () = session.watch_end.notified() => {}
                }
            }
        }))
    }

    /// Appends what `lines` add as history and moves the read position to `offset`, unless the
    /// chat was taken over meanwhile.
    fn show_watched(&self, session: &Session, lines: &[String], offset: u64) {
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
                crate::daemon::spawn_blocking(move || crate::adopt_live::holder(&fam, &sid, &root))
                    .await
                    .map_err(|e| RpcError::internal(e.to_string()))?;
            if let Some(live) = live {
                return Err(RpcError::invalid_params(live.refusal(&family, &id))
                    .with_data(json!({"reason": "adopt.live", "details": live.details(&family)})));
            }
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
        session.watch_end.notify_one();
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

    /// The watch's own read opens the transcript, and Linux inotify reports that open
    /// (`notify` watches `IN_OPEN`): an open or a read is no change, or each read wakes the
    /// next one and an idle watch spins. A write, a new file, a rename or a delete is one.
    #[test]
    fn opening_or_reading_the_transcript_is_no_change() {
        use notify::event::{
            AccessKind, AccessMode, CreateKind, DataChange, EventKind, ModifyKind, RemoveKind,
        };
        let file = Path::new("/projects/-w/chat.jsonl");
        let event = |kind| notify::Event::new(kind).add_path(file.to_owned());
        let name = file.file_name().unwrap();
        for kind in [
            EventKind::Access(AccessKind::Open(AccessMode::Any)),
            EventKind::Access(AccessKind::Read),
            EventKind::Access(AccessKind::Close(AccessMode::Read)),
        ] {
            assert!(!changes_file(&event(kind), name), "{kind:?} woke the watch");
        }
        for kind in [
            EventKind::Modify(ModifyKind::Data(DataChange::Any)),
            EventKind::Access(AccessKind::Close(AccessMode::Write)),
            EventKind::Create(CreateKind::File),
            EventKind::Remove(RemoveKind::File),
        ] {
            assert!(changes_file(&event(kind), name), "{kind:?} did not wake the watch");
        }
        let other = notify::Event::new(EventKind::Create(CreateKind::File))
            .add_path(std::path::PathBuf::from("/projects/-w/other.jsonl"));
        assert!(!changes_file(&other, name), "another file's change woke the watch");
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

    /// A watcher can fail to start (Linux allows 128 inotify instances per user by default, one
    /// per watched chat): the chat still shows what its transcript holds.
    #[tokio::test]
    async fn a_watch_whose_folder_watcher_fails_still_shows_the_transcript() {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-watch-nowatcher-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout.jsonl");
        let event = |kind: &str, message: &str| json!({"timestamp": "2026-10-18T09:00:00.000Z", "type": "event_msg", "payload": {"type": kind, "message": message}});
        let records = [
            json!({"type": "session_meta", "payload": {"id": "a", "cwd": "/"}}),
            event("user_message", "first prompt"),
            event("agent_message", "first answer"),
            json!({"type": "event_msg", "payload": {"type": "task_complete"}}),
        ];
        let text: String = records.iter().map(|r| format!("{r}\n")).collect();
        std::fs::write(&file, text).unwrap();
        let mut cfg = crate::config::Config::default();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s-watch", "name": "watch",
            "harness": "codex", "cwd": "/", "status": "idle", "createdAt": 0, "updatedAt": 0,
        }))
        .unwrap();
        meta.watching = Some(Watching {
            family: "codex".into(),
            file: file.clone(),
            offset: 0,
            codex_items: false,
            open: None,
        });
        let session = hub.make_session(meta);
        let follow = hub.follow_watch(&session, |_| None).expect("a watched session is followed");
        follow.await.unwrap();
        let prompts: Vec<String> = hub
            .events(&session.id, 0, 100)
            .unwrap()
            .into_iter()
            .filter(|e| e.kind == "user_message")
            .filter_map(|e| e.msg["text"].as_str().map(str::to_owned))
            .collect();
        assert_eq!(prompts, ["first prompt"]);
        let len = std::fs::metadata(&file).unwrap().len();
        assert_eq!(session.meta().watching.map(|w| w.offset), Some(len));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
