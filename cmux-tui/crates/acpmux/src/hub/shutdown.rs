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
    /// Whether a shutdown began that hands `session`'s agent to the next daemon (no `endAgents`
    /// for it): a turn its agent's end cuts from now on is that daemon's to continue
    /// (`restart_resume.rs`). The shutdown ends or detaches agents only after `started` is set, so
    /// an end it caused reads this true. One read true may also have come on its own just before:
    /// that turn was cut too, and the next daemon continues it as this one would have.
    pub(super) fn hands_off(&self, session: &Session) -> bool {
        let plan = self.shutdown_plan.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        plan.started && (!plan.end_agents || plan.keep.contains(&session.id))
    }

    /// `f`, unless a shutdown began, under the shutdown's plan: the shutdown begins wholly before
    /// or after it. For a record the next daemon acts on (a scheduled retry, `auto_resume.rs`),
    /// which a check before writing it would leave to a shutdown beginning in between.
    pub(super) fn before_shutdown<T>(&self, f: impl FnOnce() -> T) -> Option<T> {
        let plan = self.shutdown_plan.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        (!plan.started).then(f)
    }

    pub(crate) fn shutting_down(&self) -> bool {
        // A poisoned plan still says whether the shutdown began.
        self.shutdown_plan.lock().unwrap_or_else(std::sync::PoisonError::into_inner).started
    }

    /// Fences new turns and automatic continuations before transports begin draining.
    pub(crate) fn begin_shutdown(&self) {
        self.shutdown_plan.lock().unwrap().started = true;
    }

    /// Stop every agent at once and save. Each agent's process group gets
    /// SIGTERM, then SIGKILL after `SHUTDOWN_GRACE`; every wait here has a
    /// deadline, so this returns within about `SHUTDOWN_GRACE` + 1 s.
    /// Agents under hosts are detached and keep running, unless
    /// `end_agents_at_shutdown` asked to end them: then they end through
    /// their host (else by nonce proof), and a turn in progress is recorded
    /// as cancelled. Returns how many hosted agents it left running for the
    /// next daemon (the local router stays for them).
    pub async fn shutdown_all(&self) -> usize {
        self.shutdown_all_with_auto_resume(false).await
    }

    /// Shutdown for a supervisor handoff: keep durable provider retries so the next daemon
    /// restores them at their recorded reset deadline.
    pub(crate) async fn shutdown_all_with_auto_resume(&self, preserve_auto_resume: bool) -> usize {
        // Pooled sessions are hidden, never user sessions: they end with the
        // daemon, alongside the sessions below.
        let ((), kept) =
            tokio::join!(self.stop_pool(), self.shutdown_sessions(preserve_auto_resume));
        self.seal();
        kept
    }

    /// Nothing this daemon does from here on reaches the log: the next daemon may read it before
    /// this process exits, and finds a turn whose end came later cut, not ended, and continues it
    /// (`restart_resume.rs`). Synced again for what came in after the last flush.
    pub fn seal(&self) {
        self.store.seal();
        if let Err(e) = self.store.flush() {
            tracing::warn!("store flush failed: {e}");
        }
    }

    async fn shutdown_sessions(&self, preserve_auto_resume: bool) -> usize {
        const LOCK: std::time::Duration = std::time::Duration::from_millis(200);
        // The longest a detach under way takes to end its agent (`Session::detaching`).
        const DETACH: std::time::Duration = crate::agent::KILL_GRACE.saturating_add(LOCK);
        // How long the turn ends under way get to land (`settle_ends`), within the grace.
        let now = tokio::time::Instant::now();
        let ends_by = now.checked_add(SHUTDOWN_GRACE).unwrap_or(now);
        // The idle reaper must not end a hosted agent this shutdown hands off.
        self.stop_idle_reaper();
        // A pass that already started finishes first (bounded by its kills).
        drop(self.idle_pass.lock().await);
        let (end_agents, keep) = {
            let mut plan = self.shutdown_plan.lock().unwrap();
            plan.started = true;
            (plan.end_agents, plan.keep.clone())
        };
        // The log retention worker sees the shutdown begun and ends (`retention.rs`).
        self.retention_wake.notify_one();
        let sessions = self.sessions();
        // A scheduled provider retry must not survive an explicit daemon shutdown: settle it
        // before teardown so restart restoration cannot replay it. A turn this shutdown cuts
        // is still the next daemon's to continue (`restart_resume.rs`).
        if !preserve_auto_resume {
            for s in &sessions {
                self.stop_retry_at_shutdown(s);
            }
        }
        // Startup may have been cancelled before adoption reached these hosts. Keep their
        // state and router on an ordinary restart, even when no child link exists yet.
        let live = tokio::task::spawn_blocking(Self::read_live_host_sessions).await.ok().flatten();
        let mut children = Vec::new();
        let mut hosted = Vec::new();
        // Sessions whose agent host must end without its link: no child
        // here (an unadopted host), a lock that timed out, or a hosted child
        // whose link may be closed. `end_unadopted_host` ends it with nonce
        // proof, the same fallback as closing the session.
        let mut host_fallback = Vec::new();
        let mut unreached = 0;
        for s in &sessions {
            let ends = end_agents && !keep.contains(&s.id);
            let reached = match tokio::time::timeout(LOCK, s.child.lock()).await {
                Ok(slot) => Some(slot),
                // A detach that decided before the shutdown began is ending this agent
                // (`detach_child`): the agent is not kept. Wait for that end, which takes at most
                // the agent's kill grace (router review of #28503).
                Err(_) if s.detaching.load(Ordering::SeqCst) => {
                    tokio::time::timeout(DETACH, s.child.lock()).await.ok()
                }
                Err(_) => None,
            };
            let Some(mut slot) = reached else {
                // The child cannot be reached here. Detach mode leaves it and
                // its permission prompts alone for the next daemon.
                if ends {
                    host_fallback.push(s.clone());
                    self.settle_cancelled(s);
                } else {
                    // It may run under a host: count it as kept.
                    unreached += 1;
                }
                continue;
            };
            if !ends && slot.is_none() && live.as_ref().is_none_or(|live| live.contains(&s.id)) {
                unreached += 1;
                continue;
            }
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
                // Handed to the next daemon, which continues it (`restart_resume.rs`): its
                // prompt future ends with the agent and must write no end of its own, or a
                // next daemon that reads the log after it finds no cut turn. The shutdown's lock
                // first, as `finish_turn` takes them.
                let mut settled =
                    self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
                let turn = s.turn.lock().unwrap_or_else(|e| e.into_inner()).take();
                settled.extend(turn.map(|t| t.turn_id));
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
        self.settle_ends(&sessions, end_agents, &keep, ends_by).await;
        for s in &sessions {
            let _ = self.store_deferred(s);
        }
        self.flush();
        hosted.len() + unreached
    }

    /// Turns whose end `finish_turn` took before the shutdown took them get until `by` to write
    /// it; the shutdown settles the rest as it settled the turns it took (Sol review of #28503):
    /// cancelled for Quit Everything, else handed on. Under the shutdown's lock, which a turn's
    /// end holds while it writes: each turn gets one end.
    async fn settle_ends(
        &self,
        sessions: &[Arc<Session>],
        end_agents: bool,
        keep: &std::collections::HashSet<String>,
        by: tokio::time::Instant,
    ) {
        let under_way = |s: &Arc<Session>| {
            s.ending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
        };
        loop {
            let moved = self.ends_moved.notified();
            tokio::pin!(moved);
            moved.as_mut().enable();
            if !sessions.iter().any(under_way) {
                break;
            }
            if tokio::time::timeout_at(by, moved).await.is_err() {
                break;
            }
        }
        let mut settled = self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
        for s in sessions {
            let ending = s.ending.lock().unwrap_or_else(|e| e.into_inner()).take();
            let Some(turn) = ending else { continue };
            settled.insert(turn.turn_id.clone());
            if end_agents && !keep.contains(&s.id) {
                self.write_cancelled(s, &turn);
            }
        }
    }

    /// Quit Everything: the turn in progress ends as cancelled (one
    /// `turn_result`, the record every reader treats as the turn's end), and
    /// its prompt future writes nothing more.
    fn settle_cancelled(&self, s: &Arc<Session>) {
        // The shutdown's lock first, as `finish_turn` takes them.
        let mut settled = self.settled_by_shutdown.lock().unwrap_or_else(|e| e.into_inner());
        let Some(turn) = s.turn.lock().unwrap_or_else(|e| e.into_inner()).take() else { return };
        settled.insert(turn.turn_id.clone());
        drop(settled);
        self.write_cancelled(s, &turn);
    }

    /// The cancelled end Quit Everything gives a turn in progress (`settle_cancelled`).
    fn write_cancelled(&self, s: &Arc<Session>, turn: &TurnInfo) {
        let result = json!({"status": "cancelled", "stopReason": "cancelled", "detail": "quit", "turnId": turn.turn_id, "promptId": turn.prompt_id, "turnSeq": turn.turn_seq, "trigger": turn.trigger});
        self.end_trigger_background(s, &turn.turn_id);
        // Trigger results stay in the journal without moving the human-facing last turn.
        self.record_last_turn(s, &result);
        self.append(s, "mux", "turn_result", result);
    }

    /// Save every session's meta and sync the event log to disk.
    pub fn flush(&self) {
        // Each chat's last change is on disk before this returns, also while another save of it
        // runs: the seal that follows refuses every later write.
        for s in self.sessions() {
            if let Err(e) = self.write_meta(&s) {
                tracing::error!(session = %s.id, "save meta at shutdown failed: {e}");
            }
        }
        if let Err(e) = self.store.flush() {
            tracing::warn!("store flush failed: {e}");
        }
        // What peers' sessions streamed in the last seconds (`peer_snapshot.rs`): the shutdown's
        // is its last step, after the teardown, and a shutdown past its budget calls it too.
        self.peer_snapshots.flush_now();
    }
}

/// The refusal of a spawn once the shutdown has begun (`recovery.rs` types it).
pub const SHUTTING_DOWN: &str = "acpmux is shutting down; no agent starts now";

/// The refusal of a spawn once the shutdown has begun.
pub(crate) fn shutting_down_error() -> RpcError {
    RpcError::internal(SHUTTING_DOWN)
}

/// How long agents get between SIGTERM and SIGKILL when the daemon stops.
pub const SHUTDOWN_GRACE: std::time::Duration = std::time::Duration::from_secs(2);
