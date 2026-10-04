//! Part of `Hub`; see `hub/mod.rs`. Stopping every agent when the daemon
//! stops: detach agents under hosts, or end them (`_acpmux/shutdown endAgents`).

use super::*;

impl Hub {
    /// The coming shutdown ends hosted agents too (the app's Quit
    /// Everything), except those of the sessions in `keep` (the app's Home
    /// Chief), which detach; without it a shutdown detaches every one.
    pub fn end_agents_at_shutdown(&self, keep: std::collections::HashSet<String>) {
        *self.keep_on_shutdown.lock().unwrap() = keep;
        self.end_agents_on_shutdown.store(true, Ordering::SeqCst);
    }

    /// Stop every agent at once and save. Each agent's process group gets
    /// SIGTERM, then SIGKILL after `SHUTDOWN_GRACE`; every wait here has a
    /// deadline, so this returns within about `SHUTDOWN_GRACE` + 1 s.
    /// Agents under hosts are detached and keep running, unless
    /// `end_agents_at_shutdown` asked to end them: then they end through
    /// their host, and a turn in progress is recorded as cancelled.
    pub async fn shutdown_all(&self) {
        const LOCK: std::time::Duration = std::time::Duration::from_millis(200);
        let end_agents = self.end_agents_on_shutdown.load(Ordering::SeqCst);
        let keep = self.keep_on_shutdown.lock().unwrap().clone();
        let sessions = self.sessions();
        let mut children = Vec::new();
        let mut hosted = Vec::new();
        for s in &sessions {
            // An agent under a host keeps running, with its turn and its
            // permission prompts, for the next daemon to adopt.
            let mut slot = tokio::time::timeout(LOCK, s.child.lock()).await.ok();
            if (!end_agents || keep.contains(&s.id))
                && let Some(child) =
                    slot.as_ref().and_then(|g| g.as_ref()).filter(|c| c.host_record().is_some())
            {
                hosted.push(child.clone());
                continue;
            }
            let taken = slot.as_mut().and_then(|g| g.take());
            drop(slot);
            self.revoke_permission_chat(s);
            self.cancel_pending_permissions(s);
            children.extend(taken);
            let turn = s.turn.lock().unwrap().take();
            if end_agents && let Some(turn) = turn {
                self.append(
                    s,
                    "mux",
                    "turn_cancelled",
                    json!({"reason": "quit", "turnId": turn.turn_id, "promptId": turn.prompt_id, "turnSeq": turn.turn_seq}),
                );
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
        self.flush();
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

/// How long agents get between SIGTERM and SIGKILL when the daemon stops.
pub const SHUTDOWN_GRACE: std::time::Duration = std::time::Duration::from_secs(2);
