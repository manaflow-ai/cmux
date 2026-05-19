//! Agent hook/status detection shared by Linux frontends.

use crate::session::{AgentKind, SessionStatus};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentStatusEvent {
    pub agent: AgentKind,
    pub status: SessionStatus,
    pub reason: String,
}

#[must_use]
pub fn detect_status(agent: &AgentKind, output: &str) -> Option<AgentStatusEvent> {
    let normalized = output.to_ascii_lowercase();
    if contains_waiting_signal(&normalized) {
        Some(AgentStatusEvent {
            agent: agent.clone(),
            status: SessionStatus::WaitingForInput,
            reason: "agent output indicates it is waiting for user input".to_string(),
        })
    } else {
        None
    }
}

fn contains_waiting_signal(output: &str) -> bool {
    [
        "waiting for input",
        "needs input",
        "requires your input",
        "please respond",
        "do you want to proceed",
    ]
    .iter()
    .any(|signal| output.contains(signal))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_waiting_for_input_phrases() {
        let event = detect_status(&AgentKind::Claude, "Claude needs input before continuing")
            .expect("status event");

        assert_eq!(event.agent, AgentKind::Claude);
        assert_eq!(event.status, SessionStatus::WaitingForInput);
    }

    #[test]
    fn ignores_regular_output() {
        assert_eq!(detect_status(&AgentKind::Codex, "compiling crate"), None);
    }
}
