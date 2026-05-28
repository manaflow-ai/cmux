use crate::state::Session;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Adapter {
    pub id: &'static str,
    pub display_name: &'static str,
    pub status_key: &'static str,
    pub hook_store_suffix: &'static str,
    pub feature_gaps: &'static [&'static str],
}

const CLAUDE_GAPS: &[&str] = &[
    "permission and exit-plan prompts are read-only",
    "transcript preview is limited to exported snapshot fields",
];

const CODEX_GAPS: &[&str] = &[
    "sandbox and approval controls are read-only",
    "resume does not yet preserve the full launch environment",
];

const OPENCODE_GAPS: &[&str] = &[
    "live opencode.db tailing is not implemented",
    "OpenCode pane orchestration only appears when exported in state JSON",
];

const PI_GAPS: &[&str] = &[
    "project registry metadata is not loaded yet",
    "extension approval events are read-only",
];

pub const ADAPTERS: &[Adapter] = &[
    Adapter {
        id: "claude",
        display_name: "Claude Code",
        status_key: "claude",
        hook_store_suffix: "claude",
        feature_gaps: CLAUDE_GAPS,
    },
    Adapter {
        id: "codex",
        display_name: "Codex",
        status_key: "codex",
        hook_store_suffix: "codex",
        feature_gaps: CODEX_GAPS,
    },
    Adapter {
        id: "opencode",
        display_name: "OpenCode",
        status_key: "opencode",
        hook_store_suffix: "opencode",
        feature_gaps: OPENCODE_GAPS,
    },
    Adapter {
        id: "pi",
        display_name: "Pi",
        status_key: "pi",
        hook_store_suffix: "pi",
        feature_gaps: PI_GAPS,
    },
];

pub fn adapters() -> &'static [Adapter] {
    ADAPTERS
}

pub fn adapter_by_id(id: &str) -> Option<&'static Adapter> {
    let normalized = normalize_adapter_id(id)?;
    ADAPTERS.iter().find(|adapter| adapter.id == normalized)
}

pub fn normalize_adapter_id(value: &str) -> Option<&'static str> {
    match value.trim().to_ascii_lowercase().replace('_', "-").as_str() {
        "claude" | "claude-code" | "claudecode" | "claude_code" => Some("claude"),
        "codex" | "openai-codex" => Some("codex"),
        "opencode" | "open-code" | "open_code" => Some("opencode"),
        "pi" | "pi-coding-agent" | "pi_coding_agent" => Some("pi"),
        _ => None,
    }
}

impl Adapter {
    pub fn resume_command(&self, session: &Session) -> String {
        if let Some(command) = session.resume_command.as_deref() {
            return command.to_string();
        }

        let session_id = shell_single_quoted(session.resume_session_id());
        let argv = match self.id {
            "claude" => format!("claude --resume {session_id}"),
            "codex" => format!("codex resume {session_id}"),
            "opencode" => format!("opencode --session {session_id}"),
            "pi" => format!("pi --session {session_id}"),
            _ => format!("{} {session_id}", self.id),
        };

        match session
            .cwd
            .as_deref()
            .map(str::trim)
            .filter(|cwd| !cwd.is_empty())
        {
            Some(cwd) => format!("cd {} && {argv}", shell_single_quoted(cwd)),
            None => argv,
        }
    }
}

fn shell_single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn adapter_sort_key(id: &str) -> usize {
    ADAPTERS
        .iter()
        .position(|adapter| adapter.id == id)
        .unwrap_or(usize::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{Session, SessionStatus};

    fn session(adapter: &'static str, session_id: &str) -> Session {
        Session {
            id: session_id.to_string(),
            adapter,
            session_id: Some(session_id.to_string()),
            title: "Test".to_string(),
            cwd: None,
            branch: None,
            status: SessionStatus::Completed,
            preview: None,
            details: None,
            updated_at: None,
            resume_command: None,
        }
    }

    #[test]
    fn adapters_provide_resume_commands() {
        assert_eq!(
            adapter_by_id("claude")
                .unwrap()
                .resume_command(&session("claude", "c-1")),
            "claude --resume 'c-1'"
        );
        assert_eq!(
            adapter_by_id("codex")
                .unwrap()
                .resume_command(&session("codex", "cx-1")),
            "codex resume 'cx-1'"
        );
        assert_eq!(
            adapter_by_id("opencode")
                .unwrap()
                .resume_command(&session("opencode", "oc-1")),
            "opencode --session 'oc-1'"
        );
        assert_eq!(
            adapter_by_id("pi")
                .unwrap()
                .resume_command(&session("pi", "pi-1")),
            "pi --session 'pi-1'"
        );
    }

    #[test]
    fn resume_command_prefixes_cwd() {
        let mut session = session("codex", "cx-quote");
        session.cwd = Some("/tmp/cmux user's repo".to_string());

        assert_eq!(
            adapter_by_id("codex").unwrap().resume_command(&session),
            "cd '/tmp/cmux user'\\''s repo' && codex resume 'cx-quote'"
        );
    }

    #[test]
    fn resume_command_uses_exported_command_when_available() {
        let mut session = session("codex", "cx-exported");
        session.resume_command = Some("codex resume cx-exported".to_string());

        assert_eq!(
            adapter_by_id("codex").unwrap().resume_command(&session),
            "codex resume cx-exported"
        );
    }

    #[test]
    fn adapters_record_known_feature_gaps() {
        for adapter in adapters() {
            assert!(
                !adapter.feature_gaps.is_empty(),
                "{} should name current prototype gaps",
                adapter.id
            );
        }
    }
}
