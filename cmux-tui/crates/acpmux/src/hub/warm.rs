//! Recent-project agent prewarming for the desktop ACP pane.

use super::*;

impl Hub {
    /// Starts one live child per recent project without creating or selecting
    /// sessions. Used by the desktop pane while its composer is painting.
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
            if self.child_for(&session).await.is_ok() {
                warmed.push(json!({"sessionId": session.id, "cwd": cwd}));
            }
        }
        warmed
    }
}
