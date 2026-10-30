//! Recent-project agent prewarming for the desktop ACP pane.

use super::*;

/// Which app launches may still warm one chat. Each launch names its warms and its cleanup
/// stops with one token. A warm RPC can reach the daemon after that launch's cleanup stopped
/// the chat (it was detached when the app quit); it must start nothing. Any other launch,
/// including one after a launch that never ran its cleanup (a crash), still warms the chat.
#[derive(Default)]
pub(crate) struct LaunchWarmFence {
    /// The launch that last warmed the chat: a stop without a token retires it.
    current: Option<String>,
    /// Launches whose cleanup stopped the chat, oldest first.
    retired: std::collections::VecDeque<String>,
}

impl LaunchWarmFence {
    /// Launches are rare and a late warm comes within one quit, so a few suffice.
    const RETIRED_KEPT: usize = 16;

    /// Whether a warm from `token` may start the chat: not once its launch's cleanup ran.
    pub(crate) fn admit(&mut self, token: &str) -> bool {
        if self.retired.iter().any(|retired| retired == token) {
            return false;
        }
        self.current = Some(token.to_owned());
        true
    }

    /// A launch cleanup stopped the chat: `token`'s later warms are stale. Without a token
    /// (an older app), the launch that last warmed it is retired.
    pub(crate) fn retire(&mut self, token: Option<&str>) {
        let Some(token) = token.map(str::to_owned).or_else(|| self.current.clone()) else {
            return;
        };
        if self.current.as_ref() == Some(&token) {
            self.current = None;
        }
        if !self.retired.contains(&token) {
            if self.retired.len() == Self::RETIRED_KEPT {
                self.retired.pop_front();
            }
            self.retired.push_back(token);
        }
    }
}

impl Hub {
    /// Starts one live child per recent project without creating or selecting
    /// sessions. Used by the desktop pane while its composer is painting, so no
    /// person asked: a session in the home folder, `/` or a privacy-protected
    /// folder is never warmed (`protected_folders`, LAUNCH-NO-TCC-PROMPTS). `web`: asked by a Web
    /// client (or a peer forwarding for one), for which an auto-trust rule is no Trust answer.
    /// `owner`: asked by the person's own client (`vm_boundary::owner`); no other caller starts
    /// a session at its owner's VM boundary.
    pub async fn warm_sessions(
        self: &Arc<Self>,
        requested: &[String],
        limit: usize,
        web: bool,
        owner: bool,
    ) -> Vec<Value> {
        self.warm_sessions_report(requested, limit, web, owner, None).await.0
    }

    /// The same warm operation with explicit agent-start failures. Intentional trust/protected
    /// folder skips are neither warmed nor failed. Existing callers may keep using `warm_sessions`.
    pub async fn warm_sessions_report(
        self: &Arc<Self>,
        requested: &[String],
        limit: usize,
        web: bool,
        owner: bool,
        launch_token: Option<&str>,
    ) -> (Vec<Value>, Vec<Value>) {
        // `sessions()` is newest first already; filtering keeps that order.
        let candidates: Vec<_> = if requested.is_empty() {
            self.sessions()
        } else {
            // Launch restore names explicit ids. Resolve them directly so one chat does not
            // clone and sort the daemon's entire history before every warm RPC.
            let sessions = self.sessions.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            requested.iter().filter_map(|id| sessions.get(id).cloned()).collect()
        };
        // Capture every requested generation before any one session can block startup. A Stop
        // while an earlier session loads must fence the later session's first attempt too.
        let requested_stops: std::collections::BTreeMap<_, _> = candidates
            .iter()
            .map(|session| (session.id.clone(), session.stops.load(Ordering::SeqCst)))
            .collect();
        let mut seen_cwds = std::collections::HashSet::new();
        let mut warmed = Vec::new();
        let mut failed = Vec::new();
        for session in candidates {
            if let Some(token) = launch_token {
                let admitted =
                    session.launch_warm.lock().unwrap_or_else(|e| e.into_inner()).admit(token);
                if !admitted {
                    failed.push(json!({"sessionId": session.id, "error": {"code": -32800, "message": "stale launch warm"}}));
                    continue;
                }
            }
            // An explicit Stop before the census is an intentional skip; do not reopen it.
            if session.status() == SessionStatus::Closed || session.closing.load(Ordering::SeqCst) {
                continue;
            }
            let stops =
                *requested_stops.get(&session.id).unwrap_or(&session.stops.load(Ordering::SeqCst));
            // Watched transcripts intentionally start no harness until Take Over.
            if session.meta().watching.is_some() {
                continue;
            }
            let cwd = session.meta().cwd.to_string_lossy().into_owned();
            if !seen_cwds.insert(cwd.clone()) || warmed.len() >= limit {
                continue;
            }
            // A session at its owner's VM boundary starts only for the owner's own clients
            // (`vm_boundary.rs`).
            if session.meta().vm_boundary && !owner {
                tracing::info!(session = %session.id, "not warmed: at its owner's VM boundary");
                continue;
            }
            if let Some(reason) = crate::protected_folders::unasked_refusal(&session.meta().cwd) {
                tracing::info!(session = %session.id, "not warmed: {reason}");
                continue;
            }
            // No agent starts in a folder without a Trust answer (`server/trust_gate.rs`).
            if !self.folder_trusted(&session, web).await {
                tracing::info!(session = %session.id, "not warmed: the folder has no Trust answer");
                continue;
            }
            match self.child_for_since(&session, stops).await {
                Ok(_) => warmed.push(json!({"sessionId": session.id, "cwd": cwd})),
                Err(error) => failed.push(json!({"sessionId": session.id, "error": error})),
            }
        }
        (warmed, failed)
    }

    /// Stop exactly one launch-restored session on this daemon. Missing IDs have already
    /// stopped; names and prefixes deliberately select nothing. The server requires a local
    /// Unix connection before calling this, so a peer cannot stop this host's agents.
    pub async fn warm_stop(&self, id: &str, launch_token: Option<&str>) -> Value {
        let session = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(id)
            .cloned();
        let Some(session) = session else {
            return json!({"sessionId": id, "status": "idle"});
        };
        // An idle pass finishes marking hibernation before this stop; none starts during it.
        let _using = session.harness_use.read().await;
        session.launch_warm.lock().unwrap_or_else(|e| e.into_inner()).retire(launch_token);
        let closed = session.status() == SessionStatus::Closed;
        let stops = session.stops.fetch_add(1, Ordering::SeqCst) + 1;
        session.closing.store(true, Ordering::SeqCst);
        self.clear_hibernation(&session);
        self.stop_auto_resume(&session);
        self.stop_subagent_retries(&session, closed);
        self.revoke_permission_chat(&session);
        self.cancel_pending_permissions(&session);
        for queued in session.queue() {
            self.remove_queued_because(&session, &queued.prompt_id, Some("stopped"));
        }
        self.settle_cancelled(&session, "stopped");
        // End a published child first: initialize/load may be waiting for its reply while it
        // holds spawn_lock. Then drain that start, whose stop count prevents it publishing a
        // replacement, and end any host it left behind.
        self.stop_session_child(&session, Some(stops)).await;
        let _spawning = session.spawn_lock.lock().await;
        self.stop_session_child(&session, Some(stops)).await;
        if !closed && session.stops.load(Ordering::SeqCst) == stops {
            self.set_status(&session, SessionStatus::Idle);
            session.closing.store(false, Ordering::SeqCst);
            // A close counts its stop before its status write. Do not clear that newer close.
            if session.stops.load(Ordering::SeqCst) != stops
                || session.status() == SessionStatus::Closed
            {
                session.closing.store(true, Ordering::SeqCst);
            }
        }
        json!({"sessionId": id, "status": session.status().to_string()})
    }

    /// Whether the folder-trust gate lets `session`'s agent work: always when
    /// the gate is off; else only for a Trust answer (an unreadable record is none).
    /// `web`: for a Web client, where an auto-trust rule is no answer.
    pub(super) async fn folder_trusted(&self, session: &Arc<Session>, web: bool) -> bool {
        let Some(paths) = self.trust_gate() else { return true };
        let meta = session.meta();
        let cwd = meta.cwd.to_string_lossy().into_owned();
        let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
        self.folder_trusted_cwd(paths, cwd, family, web).await
    }

    /// `folder_trusted` for a folder: `trust::session_level`, or `trust::web_session_level`
    /// for a Web client (`web`).
    pub(crate) async fn folder_trusted_cwd(
        &self,
        paths: crate::trust::Paths,
        cwd: String,
        family: String,
        web: bool,
    ) -> bool {
        let level = tokio::task::spawn_blocking(move || {
            let read = if web {
                crate::trust::web_session_level(&paths, &cwd, &family)
            } else {
                crate::trust::session_level(&paths, &cwd, &family)
            };
            read.map(|(_, level)| level)
        })
        .await;
        matches!(level, Ok(Ok(crate::trust::Level::Trusted)))
    }
}

#[cfg(test)]
mod launch_warm_fence_tests {
    use super::LaunchWarmFence;

    #[test]
    fn launch_token_fence_retires_the_last_warm_on_a_stop_without_a_token() {
        let mut fence = LaunchWarmFence::default();
        assert!(fence.admit("a"));
        fence.retire(None);
        assert!(!fence.admit("a"));
        assert!(fence.admit("b"));
    }

    #[test]
    fn launch_token_fence_keeps_only_the_newest_retired_launches() {
        let mut fence = LaunchWarmFence::default();
        for n in 0..=LaunchWarmFence::RETIRED_KEPT {
            fence.retire(Some(&n.to_string()));
        }
        assert!(fence.admit("0"), "the oldest retired launch is forgotten");
        assert!(!fence.admit(&LaunchWarmFence::RETIRED_KEPT.to_string()));
    }
}
