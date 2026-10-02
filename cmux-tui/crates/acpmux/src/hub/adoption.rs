//! Part of `Hub`; see `hub/mod.rs`. Adopting a harness's own session on
//! `session/new` (`_meta.acpmux.adopt`): the id is checked against the
//! harness store before anything is created, the session runs in the
//! conversation's recorded cwd, one id gets one session, and an agent that
//! started fresh instead of resuming fails creation.

use super::*;
use crate::adopt::AdoptRequest;

/// What adopting resolved to before a session is created.
pub(super) enum Adoption {
    /// A session already adopted this id; `session/new` returns it.
    Existing(Arc<Session>),
    /// Create a session, in the adopted conversation's recorded cwd if any.
    Found(Option<PathBuf>),
}

impl Hub {
    /// Checks `adopt` against the resolved harness and its store. No adopt
    /// resolves to `Found(None)`.
    pub(super) async fn adoption(
        &self,
        adopt: Option<&AdoptRequest>,
        agent: &str,
        family: &str,
    ) -> Result<Adoption, RpcError> {
        let Some(a) = adopt else { return Ok(Adoption::Found(None)) };
        if let Some(asked) = &a.harness
            && asked != agent
            && asked != family
        {
            return Err(RpcError::invalid_params(format!(
                "adopt names harness {asked} but the session resolves to {agent}"
            )));
        }
        if let Some(existing) = self.adopted_session(family, &a.agent_session_id) {
            return Ok(Adoption::Existing(existing));
        }
        // The store walk and the record read are file I/O.
        let homes = self.harness_homes.lock().unwrap().clone();
        let (fam, id) = (family.to_owned(), a.agent_session_id.clone());
        let found = tokio::task::spawn_blocking(move || crate::adopt::find(&fam, &id, &homes))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(RpcError::invalid_params)?;
        Ok(Adoption::Found(found.cwd))
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
        (None, None) => {
            dirs::home_dir().unwrap_or_else(|| std::env::current_dir().unwrap_or_default())
        }
    };
    let cwd = if cwd.is_absolute() {
        cwd
    } else {
        std::env::current_dir().unwrap_or_default().join(cwd)
    };
    if !cwd.is_dir() {
        return Err(RpcError::invalid_params(format!(
            "cwd {} is not a directory",
            cwd.display()
        )));
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
