//! Recent-project agent prewarming for the desktop ACP pane.

use super::*;

impl Hub {
    /// Starts one live child per recent project without creating or selecting
    /// sessions. Used by the desktop pane while its composer is painting, so no
    /// person asked: a session in the home folder, `/` or a privacy-protected
    /// folder is never warmed (`protected_folders`, LAUNCH-NO-TCC-PROMPTS).
    pub async fn warm_sessions(self: &Arc<Self>, requested: &[String], limit: usize) -> Vec<Value> {
        let mut candidates: Vec<_> = self
            .sessions()
            .into_iter()
            .filter(|s| requested.is_empty() || requested.iter().any(|id| id == &s.id))
            .collect();
        candidates.sort_by_key(|s| std::cmp::Reverse(s.meta().updated_at));
        let mut seen_cwds = std::collections::HashSet::new();
        let mut warmed = Vec::new();
        for session in candidates {
            let cwd = session.meta().cwd.to_string_lossy().into_owned();
            if !seen_cwds.insert(cwd.clone()) || warmed.len() >= limit {
                continue;
            }
            if let Some(reason) = crate::protected_folders::unasked_refusal(&session.meta().cwd) {
                tracing::info!(session = %session.id, "not warmed: {reason}");
                continue;
            }
            // No agent starts in a folder without a Trust answer (`server/trust_gate.rs`).
            if !self.folder_trusted(&session).await {
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
    async fn folder_trusted(&self, session: &Arc<Session>) -> bool {
        let Some(paths) = self.trust_gate() else { return true };
        let meta = session.meta();
        let cwd = meta.cwd.to_string_lossy().into_owned();
        let family = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
        self.folder_trusted_cwd(paths, cwd, family).await
    }

    pub(crate) async fn folder_trusted_cwd(
        &self,
        paths: crate::trust::Paths,
        cwd: String,
        family: String,
    ) -> bool {
        let level = tokio::task::spawn_blocking(move || {
            crate::trust::session_level(&paths, &cwd, &family).map(|(_, level)| level)
        })
        .await;
        matches!(level, Ok(Ok(crate::trust::Level::Trusted)))
    }
}
