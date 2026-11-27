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
                || p.previous_agent_session_ids.contains(&copy)
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

/// A fork being made for a caller that named it with a cancel token (`acp.session.fork`'s
/// `cancelToken`). Cancel can come while the history is copied, after the fork is made but
/// before its answer reaches the caller, or never: the token reaches the fork in each case.
#[derive(Default)]
pub(crate) struct PendingFork {
    cancelled: AtomicBool,
    /// The fork's id once it is made.
    made: StdMutex<Option<String>>,
}

/// The forks named by a cancel token, by token: each kept until [`KEPT_AFTER_END`] after its
/// request ended.
#[derive(Default)]
pub(crate) struct PendingForks(Arc<StdMutex<HashMap<String, Arc<PendingFork>>>>);

impl PendingForks {
    /// Drops `token`'s entry [`KEPT_AFTER_END`] from now, if it is still `pending`: one one-shot
    /// timer per entry, so none outlives that.
    fn forget_later(&self, token: &str, pending: &Arc<PendingFork>) {
        let (forks, token, pending) = (self.0.clone(), token.to_owned(), pending.clone());
        tokio::spawn(async move {
            tokio::time::sleep(KEPT_AFTER_END).await;
            let mut forks = forks.lock().unwrap_or_else(|e| e.into_inner());
            if forks.get(&token).is_some_and(|p| Arc::ptr_eq(p, &pending)) {
                forks.remove(&token);
            }
        });
    }
}

tokio::task_local! {
    static PENDING: Arc<PendingFork>;
}

/// How long a token is kept after its request ends (a cancel sent as its answer came takes the
/// fork back), or after a cancel that came before its request (that request is refused).
const KEPT_AFTER_END: std::time::Duration = std::time::Duration::from_secs(60);
const MAX_TOKEN_BYTES: usize = 128;

/// Whether the fork the running task makes was cancelled (`hub/fork.rs` checks it as it copies).
pub(crate) fn cancelled() -> bool {
    PENDING.try_with(|p| p.cancelled.load(Ordering::SeqCst)).unwrap_or(false)
}

/// The refusal a cancelled fork's request gets: nothing of the fork is left.
pub(crate) fn cancelled_refusal() -> RpcError {
    super::fork_before::refused("fork.cancelled", "the fork was cancelled")
}

impl Hub {
    /// Runs `fork` as the fork `token` names, when the caller gave one: cancelled while it runs
    /// (its admission too), it stops and leaves nothing (an error before the fork is published
    /// discards it whole), and cancelled after it is made, it is taken back before it is answered.
    /// `fork` gives the fork and what else its caller needs of it.
    pub(crate) async fn fork_cancellable<T>(
        &self,
        token: Option<&str>,
        fork: impl std::future::Future<Output = Result<(Arc<Session>, T), RpcError>>,
    ) -> Result<(Arc<Session>, T), RpcError> {
        let Some(token) = token else { return fork.await };
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(RpcError::invalid_params("cancelToken must be 1 to 128 bytes"));
        }
        let pending = Arc::new(PendingFork::default());
        {
            let mut forks = self.pending_forks.0.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(known) = forks.get(token) {
                // Cancelled before its request came (Cancel may come on another connection).
                if known.cancelled.load(Ordering::SeqCst)
                    && known.made.lock().unwrap_or_else(|e| e.into_inner()).is_none()
                {
                    return Err(cancelled_refusal());
                }
                return Err(RpcError::invalid_params("cancelToken names another fork"));
            }
            forks.insert(token.to_owned(), pending.clone());
        }
        let result = PENDING.scope(pending.clone(), fork).await;
        // Kept a while for a cancel sent as the answer came.
        self.pending_forks.forget_later(token, &pending);
        let (fork, rest) = match result {
            Ok(made) => made,
            Err(_) if pending.cancelled.load(Ordering::SeqCst) => return Err(cancelled_refusal()),
            Err(e) => return Err(e),
        };
        // Named before the flag is read: a cancel that sets it after finds the fork's id.
        *pending.made.lock().unwrap_or_else(|e| e.into_inner()) = Some(fork.id.clone());
        if pending.cancelled.load(Ordering::SeqCst) {
            let _ = self.cancel_fork(&fork).await;
            return Err(cancelled_refusal());
        }
        Ok((fork, rest))
    }

    /// Cancel for the fork `token` names: stops it while it is made, or takes it back once made.
    /// False for a token no fork has (any more); the refusal of a made fork that was used since
    /// (review of #36979: it answered true and the fork stayed).
    pub(crate) async fn cancel_pending_fork(&self, token: &str) -> Result<bool, RpcError> {
        let pending =
            self.pending_forks.0.lock().unwrap_or_else(|e| e.into_inner()).get(token).cloned();
        let Some(pending) = pending else {
            // Its request has not come yet: it is refused when it does, for a while.
            let early = Arc::new(PendingFork::default());
            early.cancelled.store(true, Ordering::SeqCst);
            let mut forks = self.pending_forks.0.lock().unwrap_or_else(|e| e.into_inner());
            if token.is_empty() || token.len() > MAX_TOKEN_BYTES || forks.contains_key(token) {
                return Ok(false);
            }
            forks.insert(token.to_owned(), early.clone());
            drop(forks);
            self.pending_forks.forget_later(token, &early);
            return Ok(true);
        };
        pending.cancelled.store(true, Ordering::SeqCst);
        let made = pending.made.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(fork) = made.and_then(|id| self.resolve(&id).ok()) {
            self.cancel_fork(&fork).await?;
        }
        Ok(true)
    }
}
