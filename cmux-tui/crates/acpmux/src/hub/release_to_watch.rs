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
//! - The chat stays writable (Leo, 2026-11-14, on the chat writable in both directions: "this
//!   is obviously what we need"). `resume-here` names its own process (`terminalPid`, checked
//!   against the kernel's peer pid), which becomes the harness; the watch records it
//!   (`Watching::terminal`) and tags the chat `via: terminal`, and the chat's prompts go into
//!   that harness (`bridge.rs`) while it runs.
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

/// The saved `terminalChatWritable` (`chat-settings.json`), off when there is none.
pub(super) fn saved_setting() -> bool {
    crate::chats::ChatSettings::load(&crate::config::home().join("chat-settings.json"))
        .terminal_chat_writable
}

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
    /// `terminal`: the process of the terminal that takes the conversation (`acpmux resume-here`,
    /// which becomes the harness): the chat's prompts go into that harness while it runs
    /// (`bridge.rs`), instead of the chat turning View Only.
    pub async fn release_to_watch(
        self: &Arc<Self>,
        session: &Arc<Session>,
        terminal: Option<u32>,
    ) -> Result<Value, RpcError> {
        // Write to a chat a terminal runs is off: the chat is a View Only watch, as before.
        let terminal = terminal.filter(|_| self.terminal_chat_writable());
        let (family, id) = self.releasable(session).await?;
        if session.meta().watching.is_some() {
            if let Some(live) = self.live_holder(session, &family, &id).await? {
                return Err(RpcError::invalid_params(live.refusal(&family, &id))
                    .with_data(json!({"reason": "adopt.live", "details": live.details(&family)})));
            }
            if let Some(pid) = terminal {
                let (_, root) = self.harness_transcript(session, &family, &id).await?;
                // Under the watch's turn gate: a watched batch writes its state back whole.
                let _turn = session.turn_lock.lock().await;
                if let Some(w) =
                    session.meta.lock().unwrap_or_else(|e| e.into_inner()).watching.as_mut()
                {
                    w.terminal = Some(driver(pid, root));
                    // A new terminal: what the last one had queued is not its own.
                    w.queued.clear();
                }
                self.save_meta(session);
                self.mark_terminal_driven(session, &family);
                drop(_turn);
                self.follow_terminal(session);
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
            let look = self.try_release(session, &family, &id, terminal).await?;
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
        terminal: Option<u32>,
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
        let (file, root) = self.harness_transcript(session, family, id).await?;
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
        let driven = terminal.is_some();
        let watching = Watching {
            family: family.to_owned(),
            file,
            offset,
            codex_items,
            open: None,
            terminal: terminal.map(|pid| driver(pid, root)),
            queued: Vec::new(),
        };
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).watching = Some(watching);
        self.save_meta(session);
        if driven {
            self.mark_terminal_driven(session, family);
        }
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

    /// Tags `session` as a chat whose prompts go into the terminal that runs its conversation: a
    /// client keeps its composer on and shows no View Only banner (webviews `bridgedWatch`). The
    /// tags only say so; what lets a prompt through is the daemon's own `Watching::terminal`.
    /// Follows the terminal `session`'s watch is bound to: once its process exits, the chat is a
    /// watch as any other again (`terminal_ended`), Take Over and Continue in New Chat back. One
    /// thread per terminal-driven chat, blocked on the kernel's exit event (pidfd, kqueue), no
    /// timer; none where the kernel has no such event (that terminal is then found gone when the
    /// chat next sends, `bridge.rs`).
    pub(super) fn follow_terminal(self: &Arc<Self>, session: &Arc<Session>) {
        let Some(driver) = session.meta().watching.and_then(|w| w.terminal) else { return };
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        // A binding a restarted daemon found while the setting is off: let go of it, never follow.
        if !self.terminal_chat_writable() {
            let (hub, session) = (self.clone(), session.clone());
            runtime.spawn(async move { hub.terminal_ended(&session, &driver).await });
            return;
        }
        let (hub, session) = (self.clone(), session.clone());
        let pid = driver.pid;
        let spawned =
            std::thread::Builder::new().name("acpmux-terminal-exit".into()).spawn(move || {
                // A later process under the same pid is not the terminal: its start time says so.
                let ours = || crate::adopt_live::pid_start_ms(pid) == driver.started;
                match crate::daemon::owner_exit::wait_process_exit(pid, ours) {
                    Ok(()) => {
                        runtime.spawn(async move { hub.terminal_ended(&session, &driver).await });
                    }
                    Err(error) => {
                        tracing::debug!(pid, %error, "the terminal's exit is not followed")
                    }
                }
            });
        if let Err(error) = spawned {
            tracing::warn!(pid, %error, "cannot follow the terminal's exit");
        }
    }

    /// The terminal `gone` a chat's watch was bound to ended: the binding, what it had queued and
    /// its tags go, so the chat is a watch as any other (read-only, Take Over). Only that very
    /// binding (pid and start time) goes: a later terminal's stays. Under the watch's turn gate,
    /// since a watched batch writes its state back whole.
    pub(super) async fn terminal_ended(
        &self,
        session: &Session,
        gone: &crate::store::TerminalDriver,
    ) {
        let _turn = session.turn_lock.lock().await;
        let cleared = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            match m.watching.as_mut() {
                Some(w) if w.terminal.as_ref() == Some(gone) => {
                    w.queued.clear();
                    w.terminal = None;
                    true
                }
                _ => false,
            }
        };
        if cleared {
            self.save_meta(session);
            self.unmark_terminal_driven(session);
        }
    }

    /// Whether a chat handed to a cmux terminal stays writable (`agents.chats.terminalChatWritable`).
    pub(crate) fn terminal_chat_writable(&self) -> bool {
        self.terminal_chat_writable.load(Ordering::SeqCst)
    }

    /// The app's `agents.chats.terminalChatWritable`. Turned off (at any time, mid-turn too),
    /// every chat a terminal drives is a View Only watch again at once: its binding and its
    /// `bridge`/`via` tags go, so the pane draws View Only and a send is refused as
    /// `watch.read_only`. Nothing is cut: the terminal's turn runs on and the watch keeps
    /// showing it, and a prompt already delivered into the terminal's harness (its inbox or
    /// queue: the harness holds it, not acpmux) runs and shows there as sent. What the watch
    /// showed of the terminal's own queue stays, so none of it shows twice.
    pub async fn set_terminal_chat_writable(self: &Arc<Self>, on: bool) {
        self.terminal_chat_writable.store(on, Ordering::SeqCst);
        if on {
            return;
        }
        for session in self.sessions() {
            let bound = session.meta().watching.and_then(|w| w.terminal);
            if let Some(driver) = bound {
                self.unbind_terminal(&session, &driver).await;
            }
        }
    }

    /// Lets go of the binding `driver` (only that very one) and its tags, keeping the watch.
    async fn unbind_terminal(
        self: &Arc<Self>,
        session: &Arc<Session>,
        driver: &crate::store::TerminalDriver,
    ) {
        let _turn = session.turn_lock.lock().await;
        let cleared = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            match m.watching.as_mut() {
                Some(w) if w.terminal.as_ref() == Some(driver) => {
                    w.terminal = None;
                    true
                }
                _ => false,
            }
        };
        if cleared {
            self.save_meta(session);
            self.unmark_terminal_driven(session);
            // What acpmux itself still held to type into the terminal goes, with why: once off,
            // nothing is written into that terminal.
            self.drop_typed(session);
        }
    }

    /// Takes off what `mark_terminal_driven` put on, once no terminal drives the chat.
    pub(super) fn unmark_terminal_driven(&self, session: &Session) {
        let driven =
            session.meta().tags.get(TERMINAL_TAG).is_some_and(|t| t.value == TERMINAL_TAG_VALUE);
        if driven {
            self.set_tags(session, None, &["bridge".to_owned(), TERMINAL_TAG.to_owned()], None);
        }
    }

    fn mark_terminal_driven(&self, session: &Session, family: &str) {
        let mut tags = serde_json::Map::new();
        tags.insert("bridge".into(), json!(family));
        tags.insert(TERMINAL_TAG.into(), json!(TERMINAL_TAG_VALUE));
        self.set_tags(session, Some(&tags), &[], None);
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

/// The tag a terminal-driven chat carries (`mark_terminal_driven`), and its value.
pub(crate) const TERMINAL_TAG: &str = "via";
pub(crate) const TERMINAL_TAG_VALUE: &str = "terminal";

/// The binding of terminal process `pid` (its start time read now) whose conversation is in `store`.
/// The cmux terminal it runs in comes from the environment the kernel recorded for its exec
/// (`hub/terminal_input.rs` `of_process`), never from what a caller sends.
fn driver(pid: u32, store: std::path::PathBuf) -> crate::store::TerminalDriver {
    let started = crate::adopt_live::pid_start_ms(pid);
    let input = super::terminal_input::of_process(pid);
    crate::store::TerminalDriver { pid, started, store, input }
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
