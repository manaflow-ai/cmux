//! Starting a chat's agent on demand (`child_for`): a prompt, a warm-up, a model or mode pick.
use super::*;

impl Hub {
    pub(super) async fn child_for(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // A watched chat starts no agent until Take Over: every lazy start (warm, model, mode, fork).
        if session.meta().watching.is_some() {
            return Err(super::watch::read_only());
        }
        self.start_child(session).await
    }

    /// `child_for` without the watch guard: Take Over starts the agent while the chat still views
    /// the conversation, so a resume that fails leaves it viewing (`watch.rs`).
    pub(super) async fn start_child(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // `ensure_child` publishes the child before `initialize` and
        // `session/load` answer (the inbound loop needs it to answer the
        // agent's own requests meanwhile). A live child is ready only while
        // no start holds the spawn lock; otherwise wait for that start below.
        if let Ok(_idle) = session.spawn_lock.try_lock()
            && let Some(child) = session.child.lock().await.as_ref()
            && child.is_alive().await
        {
            return Ok(child.clone());
        }
        self.wait_startup().await;
        let meta = session.meta();
        let agent = meta.harness.clone();
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile =
                super::resolve::session_profile(&cfg, &agent, &meta.cwd, meta.remote_origin)
                    .map_err(RpcError::invalid_params)?;
            (profile, cfg.defaults_for(&agent))
        };
        let spawn = self.spawn_profile(session, &profile, &defaults.env).await?;
        self.ensure_child(session, &spawn).await
    }

    /// Undoes a start that failed after its agent began (initialize, `session/new`, a fork's
    /// warm-up): the agent is ended, so the next start spawns afresh instead of reusing it.
    pub(super) async fn drop_started_child(&self, session: &Session) {
        if let Some(child) = session.child.lock().await.take() {
            child.terminate(super::shutdown::SHUTDOWN_GRACE).await;
        }
        if Self::host_record_live(&session.id) {
            self.end_unadopted_host(session).await;
        }
        session.loading.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}
