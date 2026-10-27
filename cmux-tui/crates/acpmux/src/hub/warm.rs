//! Recent-project agent prewarming for the desktop ACP pane.

use super::*;

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
        self.warm_sessions_report(requested, limit, web, owner).await.0
    }

    /// The same warm operation with explicit agent-start failures. Intentional trust/protected
    /// folder skips are neither warmed nor failed. Existing callers may keep using `warm_sessions`.
    pub async fn warm_sessions_report(
        self: &Arc<Self>,
        requested: &[String],
        limit: usize,
        web: bool,
        owner: bool,
    ) -> (Vec<Value>, Vec<Value>) {
        self.warm_sessions_guarded(requested, limit, web, owner, &std::collections::BTreeMap::new()).await
    }

    /// A retry keeps the original stop generation; a later explicit Stop wins over that retry.
    pub async fn warm_sessions_guarded(
        self: &Arc<Self>,
        requested: &[String],
        limit: usize,
        web: bool,
        owner: bool,
        expected_stops: &std::collections::BTreeMap<String, u64>,
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
            // An explicit Stop before the census is an intentional skip; do not reopen it.
            if session.status() == SessionStatus::Closed || session.closing.load(Ordering::SeqCst) {
                continue;
            }
            let stops =
                *requested_stops.get(&session.id).unwrap_or(&session.stops.load(Ordering::SeqCst));
            if expected_stops.get(&session.id).is_some_and(|expected| *expected != stops) {
                continue;
            }
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
                // Invalid params includes an explicit stop during startup. It must not be
                // retried with a new stop generation, which would reopen the stopped session.
                Err(error) => {
                    // Startup can outlive the socket and an explicit Stop can race it. Re-read
                    // the generation after the await so a timeout cannot be retried past Stop.
                    let current_stops = session.stops.load(Ordering::SeqCst);
                    failed.push(json!({
                        "sessionId": session.id,
                        "retryable": error.code != -32602 && current_stops == stops,
                        "stops": current_stops,
                        "error": error
                    }));
                }
            }
        }
        (warmed, failed)
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
