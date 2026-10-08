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
    Found { cwd: Option<PathBuf>, fork: bool },
}

impl Hub {
    /// Resolve the recorded folder for a prospective adoption before a session
    /// is created. The folder-trust gate uses this to block harness startup.
    pub(crate) async fn adopted_cwd_for_trust(
        &self,
        family: &str,
        agent_session_id: &str,
    ) -> Result<Option<String>, RpcError> {
        if family.is_empty() {
            return Ok(None);
        }
        let homes = self.harness_homes.lock().unwrap().clone();
        let family = family.to_owned();
        let id = agent_session_id.to_owned();
        let found = tokio::task::spawn_blocking(move || crate::adopt::find(&family, &id, &homes))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(RpcError::invalid_params)?;
        Ok(found.cwd.map(|cwd| cwd.to_string_lossy().into_owned()))
    }

    /// Checks `adopt` against the resolved harness and its store. No adopt
    /// resolves to `Found(None)`.
    pub(super) async fn adoption(
        &self,
        adopt: Option<&AdoptRequest>,
        agent: &str,
        family: &str,
        env: &[&BTreeMap<String, String>],
    ) -> Result<Adoption, RpcError> {
        let Some(a) = adopt else { return Ok(Adoption::Found { cwd: None, fork: false }) };
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
        // the daemon's. The store walk, the record read and the process
        // table are blocking I/O.
        let homes = self.harness_homes.lock().unwrap().with_env(env);
        let (fam, id, check) =
            (family.to_owned(), a.agent_session_id.clone(), a.if_live == IfLive::Refuse);
        let (found, live) = tokio::task::spawn_blocking(move || {
            let found = crate::adopt::find(&fam, &id, &homes)?;
            let live = check
                .then(|| {
                    let procs = crate::adopt_live::processes();
                    crate::adopt_live::live_use(
                        &id,
                        &found.file,
                        &procs,
                        std::time::SystemTime::now(),
                    )
                })
                .flatten();
            Ok::<_, String>((found, live))
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(RpcError::invalid_params)?;
        if let Some(live) = live {
            return Err(RpcError::invalid_params(live.refusal(family, &a.agent_session_id))
                .with_data(json!({"reason": "adopt.live", "details": live.details(family)})));
        }
        Ok(Adoption::Found { cwd: found.cwd, fork: a.if_live == IfLive::Fork })
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
        let _ = self.kill(session, true).await;
        Err(RpcError::internal(format!(
            "{agent} could not resume session {}",
            adopt.agent_session_id
        )))
    }
}

/// The new session's cwd: the one given, else the adopted conversation's
/// recorded one, else home; made absolute and required to be a directory.
pub(super) fn session_cwd(
    cwd: Option<PathBuf>,
    recorded: Option<PathBuf>,
    family: &str,
) -> Result<PathBuf, RpcError> {
    let cwd = match (cwd, recorded) {
        (Some(given), Some(recorded)) if family == "claude" && !same_dir(&given, &recorded) => {
            // Claude keeps a conversation under its cwd's project; resuming elsewhere finds nothing.
            return Err(RpcError::invalid_params(format!(
                "cwd {} does not match the adopted session's {}",
                given.display(),
                recorded.display()
            )));
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
