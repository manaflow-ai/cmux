//! Part of `Hub`; see `hub/mod.rs`. Adopting a harness's own session on
//! `session/new` (`_meta.acpmux.adopt`): the id is checked against the
//! harness store before anything is created, the session runs in the
//! conversation's recorded cwd, one id gets one session, and an agent that
//! started fresh instead of resuming fails creation. A conversation live in
//! another process is refused (`adopt.live`) unless `ifLive` forks it or
//! opens it anyway (`adopt_live.rs`).

use super::*;
use crate::adopt::{AdoptRequest, IfLive};
use std::collections::BTreeMap;

/// What adopting resolved to before a session is created.
pub(super) enum Adoption {
    /// A session already adopted this id; `session/new` returns it.
    Existing(Arc<Session>),
    /// Create a session, in the adopted conversation's recorded cwd if any;
    /// `fork`: a new conversation forked from it (`--fork-session`).
    /// `file`: the adopted conversation's transcript, replayed as history (`adopt_replay`).
    /// `store`: the chat index's store that holds it when the profile's
    /// store does not (cx-vx54).
    Found { cwd: Option<PathBuf>, fork: bool, file: Option<PathBuf>, store: Option<PathBuf> },
}

impl Hub {
    /// Resolve the recorded folder for a prospective adoption before a session
    /// is created. The folder-trust gate uses this to block harness startup.
    pub(crate) async fn adopted_cwd_for_trust(
        &self,
        family: &str,
        agent_session_id: &str,
        remote: bool,
    ) -> Result<Option<String>, RpcError> {
        if family.is_empty() {
            return Ok(None);
        }
        let homes = self.harness_homes.lock().unwrap().clone();
        let family = family.to_owned();
        let id = agent_session_id.to_owned();
        let index = self.chats.get().filter(|_| !remote).cloned();
        let (found, _) = tokio::task::spawn_blocking(move || {
            let others = indexed_stores(index.as_deref(), &family, &id);
            crate::adopt::find_any(&family, &id, &homes, &others)
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(RpcError::invalid_params)?;
        Ok(found.cwd.map(|cwd| cwd.to_string_lossy().into_owned()))
    }

    /// Checks `adopt` against the resolved harness and its store. No adopt
    /// resolves to `Found(None)`. `remote` (a Web-class connection) adopts
    /// only from a profile's store, never from another store of the index.
    pub(super) async fn adoption(
        &self,
        adopt: Option<&AdoptRequest>,
        agent: &str,
        family: &str,
        env: &[&BTreeMap<String, String>],
        remote: bool,
    ) -> Result<Adoption, RpcError> {
        let Some(a) = adopt else {
            return Ok(Adoption::Found { cwd: None, fork: false, file: None, store: None });
        };
        if let Some(asked) = &a.harness
            && asked != agent
            && asked != family
        {
            return Err(RpcError::invalid_params(format!(
                "adopt names harness {asked} but the session resolves to {agent}"
            )));
        }
        if a.if_live == IfLive::Fork && family != "claude" {
            return Err(RpcError::invalid_params(format!(
                "only Claude Code chats fork on adopt; open this {family} chat anyway or close it where it runs"
            )));
        }
        if let Some(existing) = self.adopted_session(family, &a.agent_session_id) {
            return Ok(Adoption::Existing(existing));
        }
        // The store the resuming harness reads: its spawn env's home, else
        // the daemon's, else a store the chat index holds the chat in. The
        // store walk, the record read and the process table are blocking I/O.
        let homes = self.harness_homes.lock().unwrap().with_env(env);
        let index = self.chats.get().filter(|_| !remote).cloned();
        let (fam, id, check) =
            (family.to_owned(), a.agent_session_id.clone(), a.if_live == IfLive::Refuse);
        let ((found, store), live) = tokio::task::spawn_blocking(move || {
            let others = indexed_stores(index.as_deref(), &fam, &id);
            let (found, store) = crate::adopt::find_any(&fam, &id, &homes, &others)?;
            let live = check
                .then(|| {
                    let procs = crate::adopt_live::processes();
                    if fam == "opencode" {
                        return crate::adopt_live::named_use(&id, &procs);
                    }
                    crate::adopt_live::live_use(
                        &id,
                        &found.file,
                        found.cwd.as_deref(),
                        &procs,
                        std::time::SystemTime::now(),
                    )
                })
                .flatten();
            Ok::<_, String>(((found, store), live))
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(RpcError::invalid_params)?;
        if let Some(live) = live {
            return Err(RpcError::invalid_params(live.refusal(family, &a.agent_session_id))
                .with_data(json!({"reason": "adopt.live", "details": live.details(family)})));
        }
        Ok(Adoption::Found {
            cwd: found.cwd,
            fork: a.if_live == IfLive::Fork,
            file: Some(found.file),
            store,
        })
    }

    /// The session that already adopted `agent_session_id` in `family`, so
    /// adopting twice opens the same session instead of two resuming one.
    /// Any profile of the family counts: they share one store.
    fn adopted_session(&self, family: &str, agent_session_id: &str) -> Option<Arc<Session>> {
        adopted_in(&self.sessions.lock().unwrap(), family, agent_session_id)
    }

    /// An agent that could not load the adopted session started a fresh one
    /// instead; with no acpmux history to rehydrate, that would be a new
    /// conversation posing as the adopted one, so the session is removed.
    pub(super) async fn check_resumed(
        &self,
        session: &Arc<Session>,
        adopt: &AdoptRequest,
        agent: &str,
    ) -> Result<(), RpcError> {
        if session.meta().agent_session_id.as_deref() == Some(adopt.agent_session_id.as_str()) {
            return Ok(());
        }
        // Another Codex still writing the thread (classic cmux's terminal, a bare `codex` the
        // live check cannot tie to it) refuses the load: say so, not "could not resume" (cx-l7g6k).
        let held = self.load_error(session).is_some_and(|e| e.contains("active writer"));
        let _ = self.kill(session, true).await;
        if held {
            return Err(RpcError::invalid_params(format!(
                "{agent} session {} is still open in another app, such as classic cmux: \
                 quit it there, then open it again",
                adopt.agent_session_id
            )));
        }
        Err(RpcError::internal(format!(
            "{agent} could not resume session {}",
            adopt.agent_session_id
        )))
    }

    /// Records that `session`'s agent refused its `session/load`, with the error's `data`, where
    /// codex-acp says why (its message is "Internal error").
    pub(super) fn note_load_failed(&self, session: &Session, e: &RpcError) {
        let failed = json!({"error": e.message, "data": e.data});
        self.append(session, "mux", "resume_failed", failed);
    }

    /// Why `session`'s agent refused its `session/load`, if it did: the error's message and its
    /// `data` (where codex-acp puts the reason), as one text.
    fn load_error(&self, session: &Session) -> Option<String> {
        let events = self.events(&session.id, 0, 1_000).ok()?;
        let failed = events.iter().rev().find(|e| e.dir == "mux" && e.kind == "resume_failed")?;
        let message = failed.msg.get("error").and_then(Value::as_str).unwrap_or_default();
        Some(format!("{message} {}", failed.msg.get("data").unwrap_or(&Value::Null)))
    }
}

/// The stores acpmux's chat index holds the `family` chat `id` in (none
/// before the index starts): a subrouter account home or a root the person
/// added, which adopt may resume from though no profile's store is one.
fn indexed_stores(
    index: Option<&crate::chats::ChatService>,
    family: &str,
    id: &str,
) -> Vec<PathBuf> {
    let harness = match family {
        "claude" => cmux_chat_index::AdapterKind::ClaudeCode,
        "codex" => cmux_chat_index::AdapterKind::Codex,
        "opencode" => cmux_chat_index::AdapterKind::OpenCode,
        _ => return Vec::new(),
    };
    let key = cmux_chat_index::ChatKey { harness, session_id: id.to_owned() };
    index
        .and_then(|index| index.get(&key))
        .map(|chat| crate::chats::store_dirs(&chat))
        .unwrap_or_default()
}

/// The new session's cwd: the one given, else the adopted conversation's
/// recorded one, else home; made absolute and required to be a directory.
pub(super) fn session_cwd(
    cwd: Option<PathBuf>,
    recorded: Option<PathBuf>,
    family: &str,
) -> Result<PathBuf, RpcError> {
    let cwd = match (cwd, recorded) {
        // Claude keeps a conversation under its cwd's project; resuming elsewhere finds nothing.
        // The client's folder is only its default (the page's private agent-home folder), so the
        // conversation's own folder wins while it exists (nxdog93: "cwd mismatch" on an
        // agent-home chat). A gone folder needs the person's pick (`needsFolder`).
        (Some(given), Some(recorded)) if family == "claude" && !same_dir(&given, &recorded) => {
            if !recorded.is_dir() {
                return Err(RpcError::invalid_params(format!(
                    "cwd {} does not match the adopted session's {}, which is gone",
                    given.display(),
                    recorded.display()
                )));
            }
            recorded
        }
        (Some(given), _) => given,
        (None, Some(recorded)) => recorded,
        // Never the home folder by default: an agent there reads every
        // privacy-protected folder in it (LAUNCH-NO-TCC-PROMPTS). The app
        // gives a folder (the workspace's, or agent-home).
        (None, None) => {
            return Err(RpcError::invalid_params(
                "no folder for this session: pass a cwd (the workspace folder or an agent-home folder)",
            ));
        }
    };
    let cwd =
        if cwd.is_absolute() { cwd } else { std::env::current_dir().unwrap_or_default().join(cwd) };
    if !cwd.is_dir() {
        return Err(RpcError::invalid_params(format!("cwd {} is not a directory", cwd.display())));
    }
    Ok(cwd)
}

/// The session in `sessions` that adopted `agent_session_id` in `family`.
pub(super) fn adopted_in(
    sessions: &HashMap<String, Arc<Session>>,
    family: &str,
    agent_session_id: &str,
) -> Option<Arc<Session>> {
    sessions
        .values()
        .find(|s| {
            let m = s.meta();
            m.family.as_deref() == Some(family)
                && m.agent_session_id.as_deref() == Some(agent_session_id)
        })
        .cloned()
}

/// True when both paths name one directory (`/tmp` and `/private/tmp`,
/// a trailing slash, a relative path).
fn same_dir(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

impl Hub {
    /// Appends the adopted conversation's past turns (`adopt_replay::read`) as this session's
    /// history, unless the session already shows some (a harness that sent history after its load).
    pub(super) async fn replay_adopted(&self, session: &Arc<Session>, family: &str, file: PathBuf) {
        let has_history = self.store.events(&session.id, 0, 100_000).is_ok_and(|events| {
            events.iter().any(|e| e.kind == "user_message" || e.kind == "agent_message_chunk")
        });
        if has_history {
            return;
        }
        let fam = family.to_owned();
        let Ok(turns) =
            tokio::task::spawn_blocking(move || crate::adopt_replay::read(&fam, &file)).await
        else {
            return;
        };
        if turns.is_empty() {
            return;
        }
        // The chat's title and counts come from its past, as live turns set them (turns.rs).
        {
            let mut m = session.meta.lock().unwrap();
            if m.title.is_none()
                && let Some(first) = turns[0].prompt.lines().find(|l| !l.trim().is_empty())
            {
                m.title = Some(short_text(first.trim(), 80));
            }
            if let Some(last) = turns.last() {
                m.last_prompt = Some(short_text(&last.prompt, 200));
            }
            m.turn_count += turns.len() as u64;
        }
        self.save_meta(session);
        let agent_sid = session.meta().agent_session_id.unwrap_or_default();
        for (i, turn) in turns.iter().enumerate() {
            let turn_id = format!("adopted-{i}");
            let prompt_id = format!("adopted-prompt-{i}");
            // Each record keeps the transcript's time, so a fork through it cuts Claude's
            // transcript there (`fork_at.rs`) and the turn shows its real time.
            let (started, ended) = (turn.prompt_at, turn.answer_at.or(turn.prompt_at));
            let turn_seq = self
                .append_at(
                    session,
                    "mux",
                    "turn_started",
                    json!({"prompt": turn.prompt.chars().take(200).collect::<String>(), "client": "adopt", "promptId": prompt_id, "turnId": turn_id, "control": "local"}),
                    None,
                    started,
                )
                .0
                .seq;
            self.append_at(
                session,
                "mux",
                "user_message",
                json!({"text": turn.prompt, "client": "adopt", "promptId": prompt_id, "turnId": turn_id}),
                None,
                started,
            );
            if !turn.answer.is_empty() {
                self.append_at(
                    session,
                    "in",
                    "agent_message_chunk",
                    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": agent_sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": turn.answer}}}}),
                    None,
                    ended,
                );
            }
            self.append_at(
                session,
                "mux",
                "turn_end",
                json!({"stopReason": "end_turn", "turnId": turn_id, "turnSeq": turn_seq}),
                None,
                ended,
            );
            // A settled turn: clients and restart recovery read `turn_result`, not `turn_end`.
            self.append_at(
                session,
                "mux",
                "turn_result",
                json!({"status": "completed", "stopReason": "end_turn", "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id}),
                None,
                ended,
            );
        }
    }
}
