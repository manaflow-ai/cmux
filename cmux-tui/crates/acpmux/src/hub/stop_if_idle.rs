//! A Stop that ends only an idle session: `acpmux session stop NAME --if-idle [--expect-revision
//! REV]` (`_acpmux/kill` with `ifIdle` and `expectRevision`).
//!
//! A reconciler that reads a session, decides it is idle and then stops it races every turn
//! admitted between the read and the stop: a plain stop ends that turn mid-way. This stop checks
//! under the lease a turn is admitted under (`turn_lock`, as `queue.rs` `queue_slot` takes it for
//! each prompt) and the ones an agent start or a mode change holds (`harness_use`, `spawn_lock`),
//! as the idle pass does (`idle.rs`), and stops with the turn lock still held. So no turn begins
//! between the check and the stop: one that already holds the lease makes the stop refuse, and one
//! that comes later waits for the stop to finish (it is then refused as stopped before its prompt,
//! or starts the closed session again, as after any stop).
//!
//! The session's revision is its log's last sequence (`lastSeq` in `acpmux ls --json`,
//! `session info --json`, and each record's `seq` in `session tail`). It is stored, so it only
//! grows across daemon restarts, and every turn admitted, prompt queued, tool call and permission
//! request appends a record. With `expectRevision`, a session whose revision is no longer REV is
//! refused: something happened since the caller read it.
//!
//! A turn the harness starts on its own (Claude Code's, for a task notification: it never took a
//! prompt from acpmux) takes no lock of acpmux's; nothing in this daemon can fence it. It counts
//! once its `system/init` is read (`Session::harness_turn`, after the inbound drain below), and
//! what such a turn is started for, a background subagent or process that ends, makes the session
//! busy on its own. Left open: a turn the harness starts in the moment between this check and the
//! stop, with nothing of its own running, as for the idle pass.
//!
//! A refusal is JSON-RPC error [`NOT_IDLE_CODE`] with data `{"reason": "busy" | "revision_moved",
//! "revision": N, "sessionId": ID}`, plus `busyWith` for `busy` (`turn`, `queued`, `permission`,
//! `tool_call`, `subagent`, `process`, `unstored`, `unadopted_host`, `starting`, `moving`). The
//! CLI exits 6 (`cli/errors.rs`).

use super::*;

/// Listed in `initialize`'s `_meta.acpmux.features`: this daemon takes `ifIdle` on
/// `_acpmux/kill`. An older one would ignore it and stop the session anyway, so the CLI refuses
/// to send it to a daemon that does not list it.
pub(crate) const FEATURE: &str = "stopIfIdle";
/// The JSON-RPC error code of a conditional stop's refusal.
pub(crate) const NOT_IDLE_CODE: i64 = -32030;
/// The session has work: a turn, a queued prompt, a pending permission, a tool call.
pub(crate) const BUSY: &str = "busy";
/// The session's revision moved past the one the caller expected.
pub(crate) const REVISION_MOVED: &str = "revision_moved";
/// A conditional stop of a session on a peer: refused, since an older peer would ignore the
/// condition. Run it on the session's own host.
pub(crate) const REMOTE: &str = "stop_if_idle_remote";

/// What a stop request asks beyond the stop itself.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct StopCondition {
    pub if_idle: bool,
    pub expect_revision: Option<u64>,
}

impl StopCondition {
    /// `ifIdle` and `expectRevision` from a `_acpmux/kill` request; `expectRevision` needs
    /// `ifIdle`.
    pub(crate) fn from_params(params: &Value) -> Result<Self, RpcError> {
        let if_idle = match params.get("ifIdle") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(b)) => *b,
            Some(_) => return Err(RpcError::invalid_params("ifIdle must be a boolean")),
        };
        let expect_revision = match params.get("expectRevision") {
            None | Some(Value::Null) => None,
            Some(v) => Some(v.as_u64().ok_or_else(|| {
                RpcError::invalid_params("expectRevision must be a non-negative integer")
            })?),
        };
        if expect_revision.is_some() && !if_idle {
            return Err(RpcError::invalid_params("expectRevision needs ifIdle"));
        }
        Ok(Self { if_idle, expect_revision })
    }

    /// Whether the request may ask for a conditional stop: any `ifIdle` but `false` or null, or
    /// any `expectRevision` but null, malformed ones included. A peer that would ignore the
    /// condition gets none of these (`server/peer_forward.rs`).
    pub(crate) fn asked(params: &Value) -> bool {
        params.get("ifIdle").is_some_and(|v| !matches!(v, Value::Null | Value::Bool(false)))
            || params.get("expectRevision").is_some_and(|v| !v.is_null())
    }
}

/// The refusal of a conditional stop.
pub(crate) fn refusal(
    session: &Session,
    reason: &str,
    busy_with: Option<&str>,
    revision: u64,
) -> RpcError {
    let message = match (reason, busy_with) {
        (BUSY, Some(what)) => format!("session is not idle ({what}): not stopped"),
        (REVISION_MOVED, _) => {
            format!("session changed since it was read (revision {revision}): not stopped")
        }
        _ => "session is not idle: not stopped".to_owned(),
    };
    let mut data = json!({"reason": reason, "revision": revision, "sessionId": session.id,
        "retryable": true});
    if let Some(what) = busy_with {
        data.set("busyWith", json!(what));
    }
    RpcError::new(NOT_IDLE_CODE, message).with_data(data)
}

/// The refusal of a conditional stop of a peer's session (`server/peer_forward.rs`).
pub(crate) fn remote_refusal(peer: &str) -> RpcError {
    RpcError::new(
        -32000,
        format!(
            "--if-idle runs only on the daemon that owns the session: run it on {peer} \
             (`acpmux session stop NAME --if-idle` there)"
        ),
    )
    .with_data(json!({"reason": REMOTE, "peer": peer}))
}

impl Hub {
    /// The session's revision: its log's last sequence (`lastSeq`).
    pub(crate) fn revision(session: &Session) -> u64 {
        session.meta().last_seq
    }

    /// Stop the session as `kill` does, or refuse when the condition does not hold.
    pub(crate) async fn stop(
        &self,
        session: &Arc<Session>,
        purge: bool,
        condition: StopCondition,
    ) -> Result<(), RpcError> {
        if !condition.if_idle {
            return self.kill(session, purge).await;
        }
        self.kill_if_idle(session, purge, condition.expect_revision).await
    }

    /// `kill`, only when the session is idle (and, with `expect`, still at that revision), checked
    /// and done under the leases every turn, agent start and mode change takes (module docs).
    pub(crate) async fn kill_if_idle(
        &self,
        session: &Arc<Session>,
        purge: bool,
        expect: Option<u64>,
    ) -> Result<(), RpcError> {
        let busy = |what: &str| -> Result<(), RpcError> {
            Err(refusal(session, BUSY, Some(what), Self::revision(session)))
        };
        // A prompt that took the turn lock was admitted, even before its turn shows.
        let Ok(_turn) = session.turn_lock.try_lock() else { return busy("turn") };
        // A start, a mode change, a fork or the idle pass under way.
        let Ok(using) = session.harness_use.try_write() else { return busy("starting") };
        let Ok(spawning) = session.spawn_lock.try_lock() else { return busy("starting") };
        // What the agent sent that the reader already queued (a turn Claude Code starts itself, a
        // permission request) is handled first and counts, as in the idle pass.
        let has_child = session.child.lock().await.is_some();
        if has_child {
            Self::drain_inbound(session).await;
        }
        if let Some(what) = self.busy_with(session) {
            return busy(what);
        }
        // An agent host this daemon has not adopted (it could not, or has not yet): what runs
        // there is unknown to it, and a stop would end it (`kill` ends an unadopted host). The
        // idle pass never touches such a session either: it ends only a child it holds. Records
        // that cannot be read prove no host gone (`read_live_host_sessions`): refused as well.
        if !has_child
            && session.status() != SessionStatus::Closed
            && Self::read_live_host_sessions().is_none_or(|live| live.contains(&session.id))
        {
            return busy("unadopted_host");
        }
        let revision = Self::revision(session);
        if let Some(expected) = expect
            && revision != expected
        {
            return Err(refusal(session, REVISION_MOVED, None, revision));
        }
        // The turn lock stays held through the stop, so no turn begins until the session is
        // closed. The other leases go back to what a plain stop holds: `harness_use` shared (no
        // writer gets in between), the spawn lock not at all.
        drop(spawning);
        self.kill_held(session, purge, using.downgrade()).await
    }

    /// What keeps the session from being idle, if anything.
    fn busy_with(&self, session: &Session) -> Option<&'static str> {
        if session.turn().is_some()
            || session.harness_turn.load(Ordering::SeqCst)
            || self.continuation_pending(session)
        {
            return Some("turn");
        }
        if session.queued() > 0
            || !session.queue.lock().unwrap_or_else(|e| e.into_inner()).is_empty()
        {
            return Some("queued");
        }
        if !session.pending_permissions().is_empty()
            || session.asks_in_flight.load(Ordering::SeqCst) > 0
            || self.secrets.waiting_in(&session.id)
        {
            return Some("permission");
        }
        // A request of its agent's on its way (a file read or write, a terminal, a permission
        // not shown yet).
        if session.agent_requests.load(Ordering::SeqCst) > 0 {
            return Some("tool_call");
        }
        // Work it started that runs past its own turn: a background subagent, a working
        // sub-session (`work_below.rs`).
        if session.subagents.lock().unwrap_or_else(|e| e.into_inner()).background_running() > 0
            || session.work_below_since.lock().is_ok_and(|v| *v != 0)
        {
            return Some("subagent");
        }
        // A harness's own background process (a dev server, a watcher) ends with its harness;
        // its end is also what a harness starts a turn of its own for (module docs).
        if self.any_process_running(session) {
            return Some("process");
        }
        // A Claude chat with turns but none stored: stopped, it would come back as a fresh
        // conversation (`idle.rs` keeps it awake for the same reason).
        {
            let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if m.claude_unstored && m.turn_count > 0 {
                return Some("unstored");
            }
        }
        if session.moving().is_some() {
            return Some("moving");
        }
        None
    }
}

#[cfg(test)]
#[path = "stop_if_idle_tests.rs"]
mod stop_if_idle_tests;
