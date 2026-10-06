//! Part of `Hub`; see `hub/mod.rs`. Stopping every agent when the daemon
//! stops: detach agents under hosts, or end them (`_acpmux/shutdown endAgents`).

use super::*;

/// The shutdown's decision about hosted agents (`Hub::shutdown_plan`).
#[derive(Default)]
pub(crate) struct ShutdownPlan {
    /// The shutdown read this plan; it can no longer change.
    started: bool,
    end_agents: bool,
    keep: std::collections::HashSet<String>,
}

impl Hub {
    /// The coming shutdown ends hosted agents too (the app's Quit
    /// Everything), except those of the sessions in `keep` (the app's Home
    /// Chief), which detach; without it a shutdown detaches every one.
    /// Refused once a shutdown has started: it already handed the agents
    /// off, and nothing would end them.
    pub fn end_agents_at_shutdown(
        &self,
        keep: std::collections::HashSet<String>,
    ) -> Result<(), RpcError> {
        let mut plan = self.shutdown_plan.lock().unwrap();
        if plan.started {
            return Err(RpcError::internal(
                "the daemon is already shutting down and hands its agents off; endAgents comes too late",
            ));
        }
        plan.end_agents = true;
        plan.keep = keep;
        Ok(())
    }

    /// The shutdown has begun (it read its plan): no agent may start from
    /// here on, or it would outlive the daemon with nothing to end it.
    pub(crate) fn shutting_down(&self) -> bool {
        self.shutdown_plan.lock().unwrap().started
    }

    /// Stop every agent at once and save. Each agent's process group gets
    /// SIGTERM, then SIGKILL after `SHUTDOWN_GRACE`; every wait here has a
    /// deadline, so this returns within about `SHUTDOWN_GRACE` + 1 s.
    /// Agents under hosts are detached and keep running, unless
    /// `end_agents_at_shutdown` asked to end them: then they end through
    /// their host (else by nonce proof), and a turn in progress is recorded
    /// as cancelled.
    pub async fn shutdown_all(&self) {
        // Pooled sessions are hidden, never user sessions: they end with the
        // daemon, alongside the sessions below.
        tokio::join!(self.stop_pool(), self.shutdown_sessions());
    }

    async fn shutdown_sessions(&self) {
        const LOCK: std::time::Duration = std::time::Duration::from_millis(200);
        // The idle reaper must not end a hosted agent this shutdown hands off.
        self.stop_idle_reaper();
        // A pass that already started finishes first (bounded by its kills).
        drop(self.idle_pass.lock().await);
        let (end_agents, keep) = {
            let mut plan = self.shutdown_plan.lock().unwrap();
            plan.started = true;
            (plan.end_agents, plan.keep.clone())
        };
        let sessions = self.sessions();
        let mut children = Vec::new();
        let mut hosted = Vec::new();
        // Sessions whose agent host must end without its link: no child
        // here (an unadopted host), a lock that timed out, or a hosted child
        // whose link may be closed. `end_unadopted_host` ends it with nonce
        // proof, the same fallback as closing the session.
        let mut host_fallback = Vec::new();
        for s in &sessions {
            let ends = end_agents && !keep.contains(&s.id);
            let Ok(mut slot) = tokio::time::timeout(LOCK, s.child.lock()).await else {
                // The child cannot be reached here. Detach mode leaves it and
                // its permission prompts alone for the next daemon.
                if ends {
                    host_fallback.push(s.clone());
                    self.settle_cancelled(s);
                }
                continue;
            };
            let is_hosted = slot.as_ref().is_some_and(|c| c.host_record().is_some());
            // An agent under a host keeps running, with its turn and its
            // permission prompts, for the next daemon to adopt.
            if !ends && is_hosted {
                hosted.extend(slot.as_ref().cloned());
                continue;
            }
            let taken = slot.take();
            drop(slot);
            if ends && (taken.is_none() || is_hosted) {
                host_fallback.push(s.clone());
            }
            self.revoke_permission_chat(s);
            self.cancel_pending_permissions(s);
            children.extend(taken);
            if ends {
                self.settle_cancelled(s);
            } else {
                *s.turn.lock().unwrap() = None;
            }
            if s.status() != SessionStatus::Closed {
                self.set_status(s, SessionStatus::Idle);
            }
        }
        let detach = futures::future::join_all(hosted.iter().map(|c| c.detach(SHUTDOWN_GRACE)));
        let _ = tokio::time::timeout(SHUTDOWN_GRACE + LOCK * 2, detach).await;
        let stop = futures::future::join_all(children.iter().map(|c| c.terminate(SHUTDOWN_GRACE)));
        if tokio::time::timeout(SHUTDOWN_GRACE + LOCK * 2, stop).await.is_err() {
            tracing::warn!("agents did not stop within {SHUTDOWN_GRACE:?}");
        }
        let fallback =
            futures::future::join_all(host_fallback.iter().map(|s| self.end_unadopted_host(s)));
        if tokio::time::timeout(SHUTDOWN_GRACE + LOCK * 2, fallback).await.is_err() {
            tracing::warn!("agent hosts did not end within {SHUTDOWN_GRACE:?}");
        }
        self.flush();
    }

    /// Quit Everything: the turn in progress ends as cancelled (one
    /// `turn_result`, the record every reader treats as the turn's end), and
    /// its prompt future writes nothing more.
    fn settle_cancelled(&self, s: &Arc<Session>) {
        let Some(turn) = s.turn.lock().unwrap().take() else { return };
        self.settled_by_shutdown.lock().unwrap().insert(turn.turn_id.clone());
        self.append(
            s,
            "mux",
            "turn_result",
            json!({"status": "cancelled", "stopReason": "cancelled", "detail": "quit", "turnId": turn.turn_id, "promptId": turn.prompt_id, "turnSeq": turn.turn_seq}),
        );
    }

    /// Save every session's meta and sync the event log to disk.
    pub fn flush(&self) {
        for s in self.sessions() {
            self.save_meta(&s);
        }
        if let Err(e) = self.store.flush() {
            tracing::warn!("store flush failed: {e}");
        }
    }
}

/// The refusal of a spawn once the shutdown has begun.
pub(crate) fn shutting_down_error() -> RpcError {
    RpcError::internal("acpmux is shutting down; no agent starts now")
}

/// How long agents get between SIGTERM and SIGKILL when the daemon stops.
pub const SHUTDOWN_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemoryStore;

    /// A shutdown already running (SIGTERM, or a plain `_acpmux/shutdown`)
    /// has decided to hand the agents off; a later `endAgents` cannot change
    /// that and must say so instead of reporting success.
    #[tokio::test]
    async fn end_agents_after_the_shutdown_started_is_refused() {
        let hub = Hub::new(Config::default(), Box::new(MemoryStore::default()));
        hub.shutdown_all().await;
        assert!(
            hub.end_agents_at_shutdown(Default::default()).is_err(),
            "endAgents was accepted after the shutdown had handed the agents off"
        );
    }
}
