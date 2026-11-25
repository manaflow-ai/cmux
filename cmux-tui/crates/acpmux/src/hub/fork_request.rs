//! Part of `Hub`; see `hub/mod.rs`. A fork's `requestId`: one fork per id, a retry answered
//! with the fork the first request made.
//!
//! A fork cut off by a daemon restart answers `daemon_closed`, "retryable", although the fork
//! may be made, and the retry made a second fork with the same name (cmux#50084: two live
//! sessions named `f2`). Every fork kind takes a `requestId` (`session/fork`'s
//! `_meta.acpmux.requestId`, `acp.session.fork`'s `requestId`), reserved in the source chat's meta
//! before the fork is made, as Edit and Resend's fork before a prompt reserves its own
//! (`fork_before.rs`, which keeps its stricter rules). A retry with the id gets the fork it made
//! when that fork is whole; one the restart cut off was closed at the next start
//! (`fork_start.rs`), and the retry makes the fork again, under a new id.

use super::*;
use crate::store::ForkRequest;

const MAX_REQUEST_BYTES: usize = 512;
/// The plain forks' reservations a chat keeps, newest: a retry comes within seconds of its first
/// request, and a chat forked all day keeps a meta of constant size. A fork before a prompt keeps
/// its own for good (`fork_before.rs`).
const KEPT: usize = 16;

/// Drops the oldest plain reservations past [`KEPT`] (a child id is a v7 UUID: it sorts by time).
fn forget_old(requests: &mut std::collections::BTreeMap<String, ForkRequest>) {
    let mut plain: Vec<(String, String)> = requests
        .iter()
        .filter(|(_, r)| r.prompt_id.is_empty())
        .map(|(k, r)| (r.child_id.clone(), k.clone()))
        .collect();
    if plain.len() <= KEPT {
        return;
    }
    plain.sort();
    for (_, key) in &plain[..plain.len() - KEPT] {
        requests.remove(key);
    }
}

tokio::task_local! {
    /// The id a fork with a `requestId` is made under (`fork.rs`).
    static RESERVED: String;
}

/// The id reserved for the fork the running task makes, if its request named one.
pub(super) fn reserved_id() -> Option<String> {
    RESERVED.try_with(Clone::clone).ok()
}

/// One request id at a time per chat: a retry that comes while the first still forks waits for
/// it, then finds its fork. Keyed by chat and id; an entry goes with its last holder.
static IN_FLIGHT: std::sync::LazyLock<std::sync::Mutex<Gates>> =
    std::sync::LazyLock::new(Default::default);

type Gates = std::collections::HashMap<String, std::sync::Arc<tokio::sync::Mutex<()>>>;

impl Hub {
    /// Runs `fork` once for `request` on `source`: a repeat answers the fork it made (and no
    /// admission warning). Without a request id, `fork` runs as it is.
    pub(crate) async fn fork_once(
        self: &Arc<Self>,
        source: &Arc<Session>,
        request: Option<&str>,
        fork: impl std::future::Future<Output = Result<(Arc<Session>, Option<Value>), RpcError>>,
    ) -> Result<(Arc<Session>, Option<Value>), RpcError> {
        let Some(request) = request else { return fork.await };
        if request.trim().is_empty() || request.len() > MAX_REQUEST_BYTES {
            return Err(super::fork_before::refused(
                "fork.invalid_request",
                "requestId must be a nonempty string of at most 512 bytes",
            ));
        }
        let key = format!("{}\0{request}", source.id);
        let gate = IN_FLIGHT
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry(key.clone())
            .or_default()
            .clone();
        let held = gate.lock().await;
        let result = self.fork_once_held(source, request, fork).await;
        drop(held);
        let mut in_flight = IN_FLIGHT.lock().unwrap_or_else(|e| e.into_inner());
        // The map's and ours: nobody waits behind it.
        if Arc::strong_count(&gate) == 2 {
            in_flight.remove(&key);
        }
        result
    }

    async fn fork_once_held(
        self: &Arc<Self>,
        source: &Arc<Session>,
        request: &str,
        fork: impl std::future::Future<Output = Result<(Arc<Session>, Option<Value>), RpcError>>,
    ) -> Result<(Arc<Session>, Option<Value>), RpcError> {
        let id = {
            // The reservation is read and written under the chat's fork lock, as a fork before a
            // prompt reads and writes its own.
            let _fork = source.fork_lock.lock().await;
            self.session_log(source).await;
            if let Some(saved) = source.meta().fork_requests.get(request) {
                if !saved.prompt_id.is_empty() {
                    return Err(super::fork_before::refused(
                        "fork.request_conflict",
                        "requestId already names a fork before a prompt",
                    ));
                }
                if let Some(made) = self.made_fork(source, &saved.child_id) {
                    tracing::info!(session = %source.id, fork = %made.id, "fork retried: answering the fork this requestId made");
                    return Ok((made, None));
                }
            }
            let id = uuid::Uuid::now_v7().to_string();
            {
                let mut meta = source.meta.lock().unwrap_or_else(|e| e.into_inner());
                let requests = &mut meta.fork_requests;
                requests.insert(
                    request.to_owned(),
                    ForkRequest { prompt_id: String::new(), child_id: id.clone() },
                );
                forget_old(requests);
            }
            // Durable before the fork exists: a restart after it finds the reservation.
            self.write_meta(source)
                .and_then(|()| self.store.flush_session(&source.id))
                .map_err(|e| super::fork_before::refused("fork.incomplete", &e.to_string()))?;
            id
        };
        RESERVED.scope(id, fork).await
    }

    /// The fork `id` of `source`, when it is whole and open: what a retry answers.
    fn made_fork(&self, source: &Session, id: &str) -> Option<Arc<Session>> {
        let child = self.resolve(id).ok()?;
        let meta = child.meta();
        let whole = meta.fork_start.as_ref().is_none_or(|s| s.made);
        (child.id == id
            && meta.parent_id.as_deref() == Some(source.id.as_str())
            && meta.status != SessionStatus::Closed
            && whole)
            .then_some(child)
    }
}
