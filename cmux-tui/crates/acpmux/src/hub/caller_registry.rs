//! The caller tokens earlier daemon runs gave out, kept so an agent that outlives its daemon
//! (an update, a crash, a restart) is still known by the token its harness holds
//! (`hub/person.rs` (a)).
//!
//! A caller token is HMAC-SHA256 of the run's secret, which lives in memory only
//! (`start_gate.rs` `caller_token`), so each run's tokens differ. Before this file, a run knew an
//! earlier run's token only through the record of an agent host it adopted
//! (`HostRecord::caller_token`): while a host's hello was late (a loaded Mac, cmuxterm-hq#5545),
//! its record could not be read, or the token came from a workflow runner the earlier run
//! started, the agent's every `acpmux send` went out as "no proven session" until
//! `acpmux session restart`.
//!
//! Kept in `caller-tokens.json` beside config.json, owner-only (written through
//! `config::write_atomic`, read through `config::private_state_file`, which refuses a file
//! another user or group may write: a hash added there would prove a token of the writer's
//! choice). It holds no token: per session, the SHA-256 of each token it accepts
//! (`acpmux-caller-token-v1` 0 token), which proves nothing to anyone who reads it, and the
//! incarnation of the host whose harness started with the newest one.
//!
//! Which tokens count, per session:
//! - a new host of the session starts (`start_hosted`, a pooled host's adoption): only this
//!   run's token, the one its harness got; an earlier run's stops counting, as its process group
//!   is gone (`forget_adopted_caller`);
//! - this run gives the session's token to another process (a workflow runner): this run's
//!   token counts too, beside the host's, at most [`MAX_ISSUED`] of them (the oldest dropped
//!   first; the host's own token is never dropped for one);
//! - the session's agent starts without a host (`ACPMUX_AGENT_HOSTS=0`), so it ends with this
//!   run, or the session is purged: none (`forget`);
//! - at most [`MAX_SESSIONS`] sessions, the oldest dropped first.
//!
//! A token still proves only a session this daemon has (`Hub::proven_caller`).

use super::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The file's name, beside config.json.
const FILE: &str = "caller-tokens.json";
/// The most tokens given to other processes one session's entry keeps.
const MAX_ISSUED: usize = 4;
/// The most sessions the file keeps.
const MAX_SESSIONS: usize = 1024;

/// What the file holds.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Registry {
    sessions: BTreeMap<String, Entry>,
}

/// One session's accepted tokens.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Entry {
    /// SHA-256 ([`digest`]) of the token the session's newest host started its harness with.
    host: Option<String>,
    /// The incarnation of that host.
    incarnation: Option<String>,
    /// SHA-256 of each token given to another process since, oldest first.
    issued: Vec<String>,
    /// When the entry last changed (ms), for dropping the oldest.
    at_ms: u64,
}

/// The registry of one daemon: the file's contents, loaded when the hub is built, and where it
/// is saved (`None`: a daemon with no config file keeps it in memory).
pub(crate) struct CallerRegistry {
    path: Option<PathBuf>,
    state: StdMutex<Registry>,
}

/// The stored form of `token`: lowercase hex SHA-256 of "acpmux-caller-token-v1" 0 token.
fn digest(token: &str) -> String {
    let mut message = b"acpmux-caller-token-v1".to_vec();
    message.push(0);
    message.extend_from_slice(token.as_bytes());
    crate::sha256::sha256_hex(&message)
}

/// Where the registry is kept: beside config.json, if the daemon has one.
pub(super) fn state_file(cfg: &Config) -> Option<PathBuf> {
    cfg.path.as_ref().and_then(|p| p.parent()).map(|dir| dir.join(FILE))
}

impl CallerRegistry {
    /// The registry saved at `path`, read now; empty when there is none or it cannot be read.
    pub(super) fn load(path: Option<PathBuf>) -> Self {
        let state = path.as_deref().and_then(read).unwrap_or_default();
        Self { path, state: StdMutex::new(state) }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Registry> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Whether `token` is one `session`'s entry accepts (constant time per hash).
    pub(super) fn proves(&self, session: &str, token: &str) -> bool {
        if !super::person::valid_key(token) {
            return false;
        }
        let wanted = digest(token);
        self.lock().sessions.get(session).is_some_and(|entry| {
            entry
                .host
                .iter()
                .chain(&entry.issued)
                .any(|known| cmux_local_auth::tokens_match(&wanted, known))
        })
    }

    /// Whether the host `incarnation` of `session` started with a token the entry accepts.
    pub(super) fn knows_host(&self, session: &str, incarnation: &str) -> bool {
        self.lock().sessions.get(session).is_some_and(|entry| {
            entry.host.is_some() && entry.incarnation.as_deref() == Some(incarnation)
        })
    }

    /// A new host `incarnation` of `session` started with `token`: it is the one token counted.
    pub(super) fn host_started(&self, session: &str, token: &str, incarnation: &str) {
        self.change(session, |entry| {
            *entry = Entry {
                host: Some(digest(token)),
                incarnation: Some(incarnation.to_owned()),
                ..Entry::default()
            };
        });
    }

    /// `token` of `session` went to another process: it counts too.
    pub(super) fn issued(&self, session: &str, token: &str) {
        let hash = digest(token);
        self.change(session, |entry| {
            if entry.host.as_ref() != Some(&hash) && !entry.issued.contains(&hash) {
                entry.issued.push(hash);
            }
            let excess = entry.issued.len().saturating_sub(MAX_ISSUED);
            entry.issued.drain(..excess);
        });
    }

    /// No earlier run's token proves `session` in a later run: its agent ends with this run (it
    /// has no host), or the session is gone.
    pub(super) fn forget(&self, session: &str) {
        let mut state = self.lock();
        if state.sessions.remove(session).is_some() {
            self.save(&state);
        }
    }

    /// Applies `edit` to `session`'s entry and saves the registry when it changed.
    fn change(&self, session: &str, edit: impl FnOnce(&mut Entry)) {
        let mut state = self.lock();
        let before = state.sessions.get(session).cloned();
        let mut entry = before.clone().unwrap_or_default();
        edit(&mut entry);
        if before.as_ref().is_some_and(|b| {
            b.host == entry.host && b.incarnation == entry.incarnation && b.issued == entry.issued
        }) {
            return;
        }
        entry.at_ms = now_ms();
        state.sessions.insert(session.to_owned(), entry);
        while state.sessions.len() > MAX_SESSIONS {
            let oldest =
                state.sessions.iter().min_by_key(|(_, e)| e.at_ms).map(|(id, _)| id.clone());
            let Some(oldest) = oldest else { break };
            state.sessions.remove(&oldest);
        }
        self.save(&state);
    }

    /// Writes `state` to the file, if the registry has one.
    fn save(&self, state: &Registry) {
        let Some(path) = &self.path else { return };
        let saved = serde_json::to_vec(state)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| crate::config::write_atomic(path, &bytes));
        if let Err(e) = saved {
            tracing::warn!(
                "{FILE} not saved: an agent that outlives this daemon may not be known by its token: {e:#}"
            );
        }
    }
}

/// The registry saved at `path`, or `None` when there is none or it is not this user's own
/// private file.
fn read(path: &Path) -> Option<Registry> {
    use std::io::Read;
    let mut file = match crate::config::private_state_file(path) {
        Ok(file) => file,
        Err(e)
            if e.downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            return None;
        }
        Err(e) => {
            tracing::warn!(
                "{FILE} not read; earlier runs' caller tokens count only by adoption: {e:#}"
            );
            return None;
        }
    };
    let mut bytes = Vec::new();
    let parsed = file
        .read_to_end(&mut bytes)
        .map_err(anyhow::Error::from)
        .and_then(|_| serde_json::from_slice(&bytes).map_err(anyhow::Error::from));
    parsed.inspect_err(|e| tracing::warn!("{FILE} not read: {e:#}")).ok()
}

#[cfg(all(test, unix))]
mod tests;
