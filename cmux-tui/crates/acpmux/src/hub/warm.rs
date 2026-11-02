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
        // `sessions()` is newest first already; filtering keeps that order.
        let candidates: Vec<_> = self
            .sessions()
            .into_iter()
            .filter(|s| requested.is_empty() || requested.iter().any(|id| id == &s.id))
            .collect();
        let mut seen_cwds = std::collections::HashSet::new();
        let mut warmed = Vec::new();
        for session in candidates {
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
            if self.child_for(&session).await.is_ok() {
                warmed.push(json!({"sessionId": session.id, "cwd": cwd}));
            }
        }
        warmed
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
