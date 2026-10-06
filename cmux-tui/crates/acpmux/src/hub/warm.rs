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
            if self.child_for(&session).await.is_ok() {
                warmed.push(json!({"sessionId": session.id, "cwd": cwd}));
            }
        }
        warmed
    }
}
