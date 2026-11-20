//! The automatic first step of `acpmux register` that `acpmux send` from an unregistered Claude
//! Code chat asks for (`_acpmux/register` with `auto`, `cli/reply_address.rs`), so the chat ends
//! up with a reply address with no person's step (ask-828b64b532).
//!
//! It is asked on every such send, so it must cost little and say each thing once:
//! - Before any proof, from what the daemon holds for the caller's inbox and token alone: the
//!   chat registered with them (nothing to do), a code still waiting for its echo, a first step
//!   for them already running (one code, never two from sends at once), or a failure kept from
//!   a recent try (said once, not re-proven on every send). Only the session's own shell holds
//!   its token, and nothing is delivered or registered here.
//! - After the proof (`register.rs`, unchanged), what to do for the conversation: a chat the
//!   bridge already reaches gets no code; a chat that has a name (registered before a restart,
//!   or listed by the bridge) is registered under that name, never renamed; any other gets the
//!   name the send asked for, when no other session has it.

use super::*;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::{Duration, Instant};

/// How long a failed automatic first step is kept, answered without a new proof.
const FAILURE_TTL: Duration = Duration::from_secs(300);

/// The caller's inbox and token: what an automatic first step is known by.
type Key = (PathBuf, String);

/// First steps running, by inbox and token.
static IN_FLIGHT: std::sync::LazyLock<std::sync::Mutex<HashSet<Key>>> =
    std::sync::LazyLock::new(Default::default);

/// Recent failures, by inbox and token: why, and when.
static FAILED: std::sync::LazyLock<std::sync::Mutex<HashMap<Key, (String, Instant)>>> =
    std::sync::LazyLock::new(Default::default);

/// A first step running for one inbox and token; released when dropped.
pub(super) struct Reservation(Key);

impl Reservation {
    /// Keeps `why` for this inbox and token for [`FAILURE_TTL`].
    pub(super) fn failed(&self, why: &str) {
        let mut failed = FAILED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        failed.insert(self.0.clone(), (why.to_owned(), Instant::now()));
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        IN_FLIGHT.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&self.0);
    }
}

/// What an automatic first step does before any proof.
pub(super) enum Step {
    /// The answer, with nothing proven, delivered or changed.
    Answer(Value),
    /// Prove the caller and go on; the reservation holds off another send's step meanwhile.
    Go(Reservation),
}

/// What the proven conversation gets.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Plan {
    /// The bridge already reaches it (its setting on, the entrypoint listed): no code, and the
    /// chat's name when it has one.
    Reachable(Option<String>),
    /// A code for this name.
    Code(String),
    /// The name asked for is another session's.
    Taken,
}

/// The chat the daemon already shows for the conversation.
#[derive(Debug, Clone)]
pub(super) struct Own {
    pub name: String,
    /// `register` registered it (`is_registered`): after a restart it needs the new token.
    pub registered: bool,
    /// The bridge watches it (a chat it listed, not one acpmux runs).
    pub watched: bool,
}

/// What `asked` (the send's name) becomes for a conversation shown as `own`, when the bridge
/// lists its entrypoint (`bridged`) and `taken` says whether another session has a name.
pub(super) fn plan(
    asked: &str,
    own: Option<Own>,
    bridged: bool,
    taken: impl Fn(&str) -> bool,
) -> Plan {
    match own {
        // Its address is its name: registering it again keeps it.
        Some(own) if own.registered => Plan::Code(own.name),
        Some(own) if bridged && own.watched => Plan::Reachable(Some(own.name)),
        Some(own) => Plan::Code(own.name),
        // The bridge lists it on its next scan, under a name of its own.
        None if bridged => Plan::Reachable(None),
        None if taken(asked) => Plan::Taken,
        None => Plan::Code(asked.to_owned()),
    }
}

/// The name of a code in `pending` still waiting for its echo from `socket` with `token`.
pub(super) fn pending_name(
    pending: &HashMap<u32, Pending>,
    socket: &Path,
    token: &str,
) -> Option<String> {
    pending
        .values()
        .find(|p| p.socket == socket && p.token == token && p.at.elapsed() < CODE_TTL)
        .map(|p| p.name.clone())
}

impl Hub {
    /// [`Step`] for the caller's `socket` and `token`, from the tokens `register` kept in `home`
    /// (`claude_peers::save_token`), the codes waiting, the steps running and recent failures.
    pub(super) fn auto_answer(&self, home: &Path, socket: &Path, token: &str) -> Step {
        let registered: Vec<(String, String)> = {
            let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
            sessions
                .values()
                .filter(|s| is_registered(s))
                .map(|s| (s.id.clone(), s.read_meta(|m| m.name.clone())))
                .collect()
        };
        if let Some((_, name)) = registered.into_iter().find(|(id, _)| {
            crate::claude_peers::kept_token(home, id)
                .is_some_and(|k| k.socket == socket && k.token == token)
        }) {
            return Step::Answer(json!({"registered": true, "name": name}));
        }
        // Held while the step is reserved: `send_code` records its code under this lock before
        // the reservation goes, so a send at the same time sees one or the other.
        let pending = PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(name) = pending_name(&pending, socket, token) {
            return Step::Answer(json!({"pending": true, "resent": false, "name": name}));
        }
        let key: Key = (socket.to_path_buf(), token.to_owned());
        {
            let mut failed = FAILED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            failed.retain(|_, (_, at)| at.elapsed() < FAILURE_TTL);
            if let Some((why, _)) = failed.get(&key) {
                return Step::Answer(json!({"failed": why, "repeat": true}));
            }
        }
        let mut running = IN_FLIGHT.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !running.insert(key.clone()) {
            return Step::Answer(json!({"pending": true, "resent": false}));
        }
        Step::Go(Reservation(key))
    }

    /// [`Plan`] for the proven conversation `claimed`, asked as `asked`.
    pub(super) async fn auto_plan(&self, claimed: &crate::claude_peers::Peer, asked: &str) -> Plan {
        let entrypoint = claimed.entrypoint.clone();
        let bridged = tokio::task::spawn_blocking(move || {
            crate::claude_peers::enabled()
                && entrypoint
                    .is_some_and(|e| crate::claude_peers::listed_entrypoints().contains(&e))
        })
        .await
        .unwrap_or(false);
        let stores = crate::hub::adoption::store_families(&*self.config.read().await);
        let sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        let shown =
            crate::hub::adoption::adopted_in(&sessions, &stores, "claude", &claimed.session_id);
        let own = shown.as_ref().map(|s| Own {
            name: s.read_meta(|m| m.name.clone()),
            registered: is_registered(s),
            watched: s.read_meta(|m| m.watching.is_some()),
        });
        let taken = |name: &str| sessions.values().any(|s| s.read_meta(|m| m.name == name));
        plan(asked, own, bridged, taken)
    }
}

#[cfg(test)]
#[path = "register_auto_tests.rs"]
mod tests;
