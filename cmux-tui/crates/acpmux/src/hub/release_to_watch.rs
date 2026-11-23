//! `_acpmux/release_to_watch {sessionId}`: a chat hands its Claude Code or Codex conversation to
//! a terminal, the inverse of `_acpmux/watch_take_over` (`watch.rs`). Toggle Terminal and Chat
//! sends it from the terminal it opens (`acpmux resume-here`, `cli/resume_here.rs`), so the
//! person sees the terminal at once, even mid-turn (Leo, 2026-11-12: terminal and GUI are two
//! live views of one session, instant both ways, mid-turn).
//!
//! - The turn is never cut off: the release waits until the chat is idle as a conditional stop
//!   reads it (`stop_if_idle.rs` `busy_with`: the turn, queued prompts, a pending permission or
//!   question, a tool call, background work), under the same leases. A prompt already queued
//!   runs first, here. A new prompt sent meanwhile is refused with `watch.releasing`, so it is
//!   never lost: the person sends it in the terminal.
//! - Then, with no turn able to start in between (`turn_lock` held through it), the harness
//!   stops as the idle pass stops it (`detach_child`: the record and the agent session id stay)
//!   and the SAME chat becomes a watch of its own transcript from the transcript's current end.
//!   So nothing the chat already shows is read again, and what the terminal appends shows once.
//!   The open chat keeps its history and scroll: no new tab, no reload.
//! - The answer is the chat's summary (with `watching`) and `resume {argv, cwd, env}`: the
//!   harness's own resume command (`claude --resume ID`, `codex resume ID`), the folder it runs
//!   in, and the store variable the chat's profile sets (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
//! - A chat that already watches its conversation answers at once, unless another app still runs
//!   it (`adopt.live`, as Take Over reads it): two terminals never both resume it. A second
//!   release while one waits is refused (`watch.release_pending`).
//!
//! Codex: a stopped codex-acp lets go of the thread's writer lock (`adoption.rs` `check_resumed`
//! names it), so `codex resume` in the terminal is its only writer.

use super::*;
use crate::store::Watching;

/// Listed in `initialize`'s `_meta.acpmux.features`: this daemon takes `_acpmux/release_to_watch`.
pub(crate) const FEATURE: &str = "releaseToWatch";
/// A prompt sent while the chat waits to hand its conversation to a terminal.
pub(crate) const RELEASING: &str = "watch.releasing";
/// A second release of a chat whose first one still waits.
pub(crate) const PENDING: &str = "watch.release_pending";
/// What keeps a chat from ever being handed off: refused at once, never waited on.
const NEVER: &[&str] = &["unstored", "unadopted_host", "moving"];
/// How often a release that waits on work no record reports (a background process) looks again.
const RECHECK: std::time::Duration = std::time::Duration::from_secs(1);

/// What a prompt gets while the chat waits to hand its conversation to a terminal.
pub(super) fn releasing_error() -> RpcError {
    RpcError::new(
        -32000,
        "watch.releasing: this chat is moving to a terminal, which runs it once the current turn \
         ends; send this there",
    )
    .with_data(json!({"reason": RELEASING}))
}

/// One look at the chat.
enum Look {
    /// Handed off: the answer.
    Released(Value),
    /// The turn lock is held: wake on its release.
    Locked,
    /// Busy with this: wake on its next record.
    Busy(&'static str),
}

/// Clears `Session::releasing` however the release ends (answered, refused, or its request
/// dropped), so the chat takes prompts again unless it was handed off.
struct Releasing<'a>(&'a Session);

impl Drop for Releasing<'_> {
    fn drop(&mut self) {
        self.0.releasing.store(false, Ordering::SeqCst);
    }
}

impl Hub {
    /// `_acpmux/release_to_watch`: waits until `session` is idle, then stops its harness and makes
    /// it watch its own transcript (module docs).
    pub async fn release_to_watch(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<Value, RpcError> {
        let (family, id) = self.releasable(session).await?;
        if session.meta().watching.is_some() {
            if let Some(live) = self.live_holder(session, &family, &id).await? {
                return Err(RpcError::invalid_params(live.refusal(&family, &id))
                    .with_data(json!({"reason": "adopt.live", "details": live.details(&family)})));
            }
            return Ok(self.released(session, &family, &id).await);
        }
        if session.releasing.swap(true, Ordering::SeqCst) {
            return Err(RpcError::new(
                -32000,
                "watch.release_pending: another terminal is already taking this chat",
            )
            .with_data(json!({"reason": PENDING})));
        }
        let _releasing = Releasing(session);
        let mut closed = session.closed.subscribe();
        loop {
            // Subscribed before the look, so a record that comes between them still wakes it.
            let mut events = self.subscribe();
            let look = self.try_release(session, &family, &id).await?;
            let wait_lock = match look {
                Look::Released(answer) => return Ok(answer),
                Look::Locked => true,
                Look::Busy(what) if NEVER.contains(&what) => {
                    return Err(super::stop_if_idle::refusal(
                        session,
                        super::stop_if_idle::BUSY,
                        Some(what),
                        Self::revision(session),
                    ));
                }
                Look::Busy(_) => false,
            };
            let own = session.id.clone();
            let record = async move {
                loop {
                    match events.recv().await {
                        Ok(ev) if ev.session_id != own => continue,
                        // Any record of its own, or records missed: look again.
                        Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                            return;
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            std::future::pending::<()>().await;
                        }
                    }
                }
            };
            tokio::select! {
                () = record => {}
                // A turn may end its records before it lets go of the lock.
                _ = session.turn_lock.lock(), if wait_lock => {}
                _ = closed.changed() => {}
                () = tokio::time::sleep(RECHECK) => {}
            }
            if session.purged.load(Ordering::SeqCst) {
                return Err(RpcError::invalid_params("the chat was deleted"));
            }
        }
    }

    /// The chat's store family (`claude` or `codex`) and its conversation id, or why it cannot
    /// be handed to a terminal.
    async fn releasable(&self, session: &Session) -> Result<(String, String), RpcError> {
        let meta = session.meta();
        let stores = super::adoption::store_families(&*self.config.read().await);
        let family = super::adoption::session_store(&stores, &meta).unwrap_or_default();
        if !matches!(family.as_str(), "claude" | "codex") {
            return Err(RpcError::invalid_params(format!(
                "only Claude Code and Codex chats resume in a terminal, not {}",
                if family.is_empty() { meta.harness.as_str() } else { family.as_str() }
            )));
        }
        let Some(id) = meta.agent_session_id.filter(|id| crate::adopt::is_bare_id(id)) else {
            return Err(RpcError::invalid_params(
                "this chat has no conversation to resume yet: send it a prompt first",
            ));
        };
        if session.moving().is_some() {
            return Err(RpcError::invalid_params(
                "this chat is moving to another machine: resume it in a terminal there",
            ));
        }
        Ok((family, id))
    }

    /// One try: when the chat is idle, the hand-off, under the leases a turn, a start and a
    /// conditional stop take (`stop_if_idle.rs`); else what it is busy with.
    async fn try_release(
        self: &Arc<Self>,
        session: &Arc<Session>,
        family: &str,
        id: &str,
    ) -> Result<Look, RpcError> {
        let Ok(_turn) = session.turn_lock.try_lock() else { return Ok(Look::Locked) };
        let Ok(using) = session.harness_use.try_write() else { return Ok(Look::Busy("starting")) };
        let Ok(_spawning) = session.spawn_lock.try_lock() else {
            return Ok(Look::Busy("starting"));
        };
        let has_child = session.child.lock().await.is_some();
        if has_child {
            Self::drain_inbound(session).await;
        }
        if let Some(what) = self.busy_with(session) {
            return Ok(Look::Busy(what));
        }
        if !has_child
            && session.status() != SessionStatus::Closed
            && Self::read_live_host_sessions().is_none_or(|live| live.contains(&session.id))
        {
            return Ok(Look::Busy("unadopted_host"));
        }
        // The transcript the watch follows; none yet refuses with nothing stopped.
        let (file, _) = self.harness_transcript(session, family, id).await?;
        // Ended as the idle pass ends it: the record and the conversation id stay.
        if has_child {
            self.detach_child(session).await;
        }
        drop(using);
        if session.status() == SessionStatus::Closed {
            let stops = session.stops.load(Ordering::SeqCst);
            self.reopen(session, stops);
        }
        // Read after the harness ended, so its last lines count as shown.
        let codex = family == "codex";
        let start = file.clone();
        let (offset, codex_items) =
            tokio::task::spawn_blocking(move || transcript_end(&start, codex))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?;
        let watching =
            Watching { family: family.to_owned(), file, offset, codex_items, open: None };
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).watching = Some(watching);
        self.save_meta(session);
        // Watchers hear it as `_acpmux/session_changed`, with the summary that has `watching`.
        self.append(
            session,
            "mux",
            "watch_started",
            json!({"family": family, "released": true, "offset": offset}),
        );
        self.start_watch(session);
        Ok(Look::Released(self.released(session, family, id).await))
    }

    /// The answer of a release: the summary and the harness's resume command.
    async fn released(&self, session: &Session, family: &str, id: &str) -> Value {
        let meta = session.meta();
        let (_, profile_env) = self.harness_env(&meta).await;
        let var = if family == "codex" { "CODEX_HOME" } else { "CLAUDE_CONFIG_DIR" };
        let mut env = serde_json::Map::new();
        if let Some(store) = meta.chat_store.as_ref() {
            env.insert(var.into(), json!(store));
        } else if let Some(home) = profile_env.get(var) {
            env.insert(var.into(), json!(home));
        }
        let argv = resume_argv(family, id);
        json!({
            "session": self.session_summary(session),
            "resume": {"argv": argv, "cwd": meta.cwd, "env": env},
        })
    }

    /// The transcript of `family` conversation `id` and the store it is in, as Take Over and
    /// adopt find it: the chat's own store, else its profile's home.
    async fn harness_transcript(
        &self,
        session: &Session,
        family: &str,
        id: &str,
    ) -> Result<(std::path::PathBuf, std::path::PathBuf), RpcError> {
        let meta = session.meta();
        let (_, env) = self.harness_env(&meta).await;
        let homes = self.harness_homes().with_env(&[&env]);
        let others: Vec<_> = meta.chat_store.clone().into_iter().collect();
        let (fam, sid) = (family.to_owned(), id.to_owned());
        let found = tokio::task::spawn_blocking(move || {
            crate::adopt::find_any(&fam, &sid, &homes, &others).map(|(found, store)| {
                let root = store.unwrap_or_else(|| match fam.as_str() {
                    "codex" => homes.codex.clone(),
                    _ => homes.claude.clone(),
                });
                (found.file, root)
            })
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
        found.map_err(|_| {
            RpcError::invalid_params(format!(
                "this chat's {family} conversation {id} is not in its store yet: send it a \
                 prompt first"
            ))
        })
    }

    /// The process that still runs `family` conversation `id`, as Take Over reads it.
    async fn live_holder(
        &self,
        session: &Session,
        family: &str,
        id: &str,
    ) -> Result<Option<crate::adopt_live::LiveUse>, RpcError> {
        let (_, root) = match self.harness_transcript(session, family, id).await {
            Ok(found) => found,
            Err(_) => return Ok(None),
        };
        let (fam, sid) = (family.to_owned(), id.to_owned());
        tokio::task::spawn_blocking(move || crate::adopt_live::holder(&fam, &sid, &root))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))
    }
}

/// The harness's own command that resumes `family` conversation `id` in a terminal.
pub(crate) fn resume_argv(family: &str, id: &str) -> Vec<String> {
    match family {
        "codex" => vec!["codex".into(), "resume".into(), id.into()],
        _ => vec!["claude".into(), "--resume".into(), id.into()],
    }
}

/// `file`'s length, and for a Codex rollout whether it is a current one whose message items are
/// its turns (`adopt_replay.rs` `record_steps`), read from its newest part. A file that is gone
/// reads as empty.
fn transcript_end(file: &std::path::Path, codex: bool) -> (u64, bool) {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(file) else { return (0, false) };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    if !codex {
        return (len, false);
    }
    const TAIL: u64 = 4 << 20;
    let mut tail = Vec::new();
    if f.seek(SeekFrom::Start(len.saturating_sub(TAIL))).is_err()
        || f.take(TAIL).read_to_end(&mut tail).is_err()
    {
        return (len, false);
    }
    let mut items = false;
    for line in tail.split(|b| *b == b'\n') {
        if let Ok(record) = serde_json::from_slice::<Value>(line) {
            crate::adopt_replay::record_steps("codex", &record, &mut items);
            if items {
                break;
            }
        }
    }
    (len, items)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resume_runs_the_harness_own_command() {
        assert_eq!(resume_argv("claude", "abc"), ["claude", "--resume", "abc"]);
        assert_eq!(resume_argv("codex", "abc"), ["codex", "resume", "abc"]);
    }

    #[test]
    fn a_rollout_with_item_kinds_is_read_by_its_items() {
        let dir = std::env::temp_dir().join(format!("acpmux-release-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rollout.jsonl");
        let item = json!({"type": "response_item", "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": "hi"}],
            "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text"]}}});
        std::fs::write(&file, format!("{item}\n")).unwrap();
        let (len, items) = transcript_end(&file, true);
        assert_eq!(len, std::fs::metadata(&file).unwrap().len());
        assert!(items);
        assert!(!transcript_end(&file, false).1);
        assert_eq!(transcript_end(&dir.join("gone.jsonl"), true), (0, false));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
