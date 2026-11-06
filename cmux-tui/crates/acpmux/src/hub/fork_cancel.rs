//! Part of `Hub`; see `hub/mod.rs`. A Fork Conversation the person cancelled
//! (`_acpmux/kill` with `cancelFork`): the fork is made by the time the pane
//! hears its id, so Cancel takes it back whole. The fork is stopped and purged,
//! and the conversation copy its agent made (Claude's or Codex's transcript of
//! the fork) is removed with it, so nothing of it is left in the harness's own
//! resume list either. Only a fork nobody has used: one with a prompt of its
//! own is the person's chat and is refused, as any chat that is not a fork.
//! (Leo, 2026-11-06: "i shuold be able to cancel a fork probably".)

use super::*;

/// The kinds that show a fork was used after it was made: a prompt sent to it, queued or run.
const USED: &[&[u8]] = &[b"user_message", b"turn_started", b"queued"];

impl Hub {
    pub async fn cancel_fork(&self, fork: &Arc<Session>) -> Result<(), RpcError> {
        let meta = fork.meta();
        let parent = meta
            .parent_id
            .as_deref()
            .and_then(|id| self.resolve(id).ok())
            .map(|parent| parent.meta());
        if meta.parent_id.is_none() || meta.fork_before.is_some() {
            return Err(RpcError::invalid_params("only a fork can be cancelled"));
        }
        // Checked and stopped under the lease each prompt is admitted under (`queue.rs`
        // `queue_slot`), as a conditional stop is (`stop_if_idle.rs`): a prompt admitted first
        // shows in the check, and one after it waits for the stop and finds the fork closed.
        let _turn = fork.turn_lock.lock().await;
        // The fork's agent start (`start_later` in `fork.rs`) holds this shared until its agent
        // is up and has reported its own session id: that start ends first, so the copy it made
        // is known below, and none starts after.
        let using = fork.harness_use.write().await;
        if fork.queued() > 0 || self.fork_was_used(fork)? {
            return Err(RpcError::invalid_params(
                "this fork has a prompt of its own, so it is a chat now; delete it instead",
            ));
        }
        let (_, harness_env) = self.harness_env(&meta).await;
        // Read before the kill purges the fork's meta from the store.
        let store_env = self.btw_store_env(&meta, &harness_env).await;
        self.kill_held(fork, true, using.downgrade()).await?;
        // Its agent may have reported its own session id while it started (Claude's
        // `--fork-session`): read after the kill, which ended that start.
        let Some(copy) = fork.meta().agent_session_id else { return Ok(()) };
        let shared = parent.as_ref().is_some_and(|p| {
            p.agent_session_id.as_deref() == Some(copy.as_str())
                || p.previous_agent_session_ids.iter().any(|id| *id == copy)
        }) || self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().any(
            |s| s.id != fork.id && s.meta().agent_session_id.as_deref() == Some(copy.as_str()),
        );
        if !shared {
            let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
            super::btw::remove_transcript(&family, &store_env, &copy);
        }
        Ok(())
    }

    /// Whether the fork's log holds a prompt after its `forked` record: read from the end,
    /// stopping there, so it costs the fork's own records, not the history it copied.
    fn fork_was_used(&self, fork: &Session) -> Result<bool, RpcError> {
        let mut used = false;
        self.store
            .scan_back(
                &fork.id,
                0,
                u64::MAX,
                &|_, kind| kind != b"forked" && !USED.contains(&kind),
                // A store that keeps parsed records skips nothing: every record comes here.
                &mut |e: EventRecord| match e.kind.as_str() {
                    "forked" => false,
                    kind if USED.contains(&kind.as_bytes()) => {
                        used = true;
                        false
                    }
                    _ => true,
                },
            )
            .map_err(|e| RpcError::internal(e.to_string()))?;
        Ok(used)
    }
}
