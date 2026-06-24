use crate::adapters::{adapter_by_id, adapters};
use crate::state::{adapter_counts, group_sessions_by_status, status_counts, HomeState};

pub fn render_once_summary(state: &HomeState) -> String {
    let mut lines = Vec::new();
    lines.push("cmux home".to_string());
    lines.push(format!("sessions: {}", state.sessions.len()));
    lines.push(format!(
        "adapters: {}",
        adapter_counts(state)
            .into_iter()
            .map(|(id, count)| format!("{id}={count}"))
            .collect::<Vec<_>>()
            .join(" ")
    ));
    lines.push(format!(
        "statuses: {}",
        status_counts(state)
            .into_iter()
            .map(|(status, count)| format!("{}={count}", status.label()))
            .collect::<Vec<_>>()
            .join(" ")
    ));

    for group in group_sessions_by_status(state) {
        lines.push(format!("{}:", group.status.label()));
        for session in group.sessions {
            let adapter = adapter_by_id(session.adapter)
                .map(|adapter| adapter.display_name)
                .unwrap_or(session.adapter);
            let cwd = session.cwd.as_deref().unwrap_or("-");
            let branch = session.branch.as_deref().unwrap_or("-");
            let resume = adapter_by_id(session.adapter)
                .map(|adapter| adapter.resume_command(&session))
                .unwrap_or_else(|| session.resume_session_id().to_string());
            let preview = session.preview.as_deref().unwrap_or("-");
            lines.push(format!(
                "- {} {} [{} @ {}] preview={} resume={}",
                adapter, session.title, cwd, branch, preview, resume
            ));
        }
    }

    lines.push("feature-gaps:".to_string());
    for adapter in adapters() {
        lines.push(format!(
            "- {}: {}",
            adapter.id,
            adapter.feature_gaps.join("; ")
        ));
    }
    lines.push(format!("task-prompt: {}", state.task_prompt));
    lines.push(String::new());
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::parse_state;

    #[test]
    fn summary_output_is_deterministic() {
        let state = parse_state(
            r#"{
              "task_prompt": "Ask all agents...",
              "sessions": [
                {
                  "id": "z",
                  "adapter": "pi",
                  "status": "completed",
                  "title": "Pi done",
                  "cwd": "/work/pi",
                  "preview": "complete"
                },
                {
                  "id": "a",
                  "source": "claude",
                  "status": "awaiting",
                  "title": "Claude wait",
                  "cwd": "/work/claude",
                  "branch": "main",
                  "preview": "approval"
                },
                {
                  "id": "b",
                  "agent": "codex",
                  "status": "working",
                  "title": "Codex run",
                  "cwd": "/work/codex",
                  "preview": "tests"
                }
              ]
            }"#,
        )
        .unwrap();

        let summary = render_once_summary(&state);

        assert!(summary.starts_with("cmux home\nsessions: 3\n"));
        assert!(summary.contains("adapters: claude=1 codex=1 opencode=0 pi=1"));
        assert!(summary.contains("statuses: awaiting=1 working=1 completed=1"));
        assert!(
            summary.find("awaiting:").unwrap() < summary.find("working:").unwrap(),
            "awaiting sessions should be listed before working sessions"
        );
        assert!(summary.contains("resume=cd '/work/codex' && codex resume 'b'"));
        assert!(summary.contains("feature-gaps:"));
        assert!(summary.ends_with("task-prompt: Ask all agents...\n"));
    }
}
