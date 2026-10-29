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
use std::time::Duration;

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
/// [`MAX_BYTES`], after a line break. A line longer than [`MAX_READ`] is skipped: its rest fails
/// to parse and is dropped.
pub(super) fn read_lines(file: &Path, offset: u64) -> std::io::Result<(Vec<String>, u64)> {
    let mut f = std::fs::File::open(file)?;
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
                let more = offset > watching.offset && !lines.is_empty();
                if offset != watching.offset {
                    hub.show_watched(&session, &lines, offset);
                }
                if !more {
                    tokio::time::sleep(POLL).await;
                }
            }
        });
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
                tokio::task::spawn_blocking(move || crate::adopt_live::holder(&fam, &sid, &root))
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
}
