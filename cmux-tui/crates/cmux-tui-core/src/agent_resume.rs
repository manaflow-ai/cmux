//! Agent-aware session resume planning.
//!
//! Ported from herdrdev/herdr `src/agent_resume.rs` at commit
//! 7b675f42af35 (Apache-2.0, see `cmux-tui/ATTRIBUTIONS.md`), modified by
//! manaflow: plans key on our hook adapter ids (one namespace instead of
//! herdr's source+agent pairs), the session references come from the
//! session journal instead of a second persistence file, and the resume
//! argv is always exact argv (never shell text), matching `workspace.run`.

use std::path::Path;

/// A validated agent session reference: an opaque id, or an absolute
/// transcript path for agents that resume by file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentSessionRef {
    pub(crate) kind: AgentSessionRefKind,
    pub(crate) value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AgentSessionRefKind {
    Id,
    Path,
}

/// One relaunch the resume flow may execute: exact argv, deduplicated so
/// a session is never resumed twice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentResumePlan {
    pub(crate) agent: String,
    pub(crate) argv: Vec<String>,
    pub(crate) dedupe_key: String,
}

const MAX_SESSION_ID_LEN: usize = 512;
const MAX_SESSION_PATH_LEN: usize = 4096;

impl AgentSessionRef {
    pub(crate) fn id(value: impl Into<String>) -> Option<Self> {
        let value = value.into();
        valid_session_id(&value).then_some(Self { kind: AgentSessionRefKind::Id, value })
    }

    pub(crate) fn path(value: impl Into<String>) -> Option<Self> {
        let value = value.into();
        valid_session_path(&value).then_some(Self { kind: AgentSessionRefKind::Path, value })
    }
}

/// Session ids are opaque data: bounded, non-empty, no control bytes.
/// They are never interpolated into shell text.
fn valid_session_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_SESSION_ID_LEN && !value.chars().any(char::is_control)
}

fn valid_session_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_SESSION_PATH_LEN
        && !value.chars().any(char::is_control)
        && Path::new(value).is_absolute()
}

/// The resume argv for one agent adapter, or `None` when the agent has no
/// known resume interface. Adapter ids are the hook/screen-detect ids the
/// journal records.
pub(crate) fn plan(agent: &str, session_ref: &AgentSessionRef) -> Option<AgentResumePlan> {
    let argv: Vec<String> = match (agent, session_ref.kind) {
        ("claude" | "claude-code", AgentSessionRefKind::Id) => {
            vec!["claude".into(), "--resume".into(), session_ref.value.clone()]
        }
        ("codex", AgentSessionRefKind::Id) => {
            vec!["codex".into(), "resume".into(), session_ref.value.clone()]
        }
        ("copilot", AgentSessionRefKind::Id) => {
            vec!["copilot".into(), format!("--resume={}", session_ref.value)]
        }
        ("devin", AgentSessionRefKind::Id) => {
            vec!["devin".into(), "--resume".into(), session_ref.value.clone()]
        }
        ("droid", AgentSessionRefKind::Id) => {
            vec!["droid".into(), "--resume".into(), session_ref.value.clone()]
        }
        ("kimi", AgentSessionRefKind::Id) => {
            vec!["kimi".into(), "--session".into(), session_ref.value.clone()]
        }
        ("pi", AgentSessionRefKind::Path | AgentSessionRefKind::Id) => {
            vec!["pi".into(), "--session".into(), session_ref.value.clone()]
        }
        ("hermes-agent" | "hermes", AgentSessionRefKind::Id) => {
            vec!["hermes".into(), "--resume".into(), session_ref.value.clone()]
        }
        ("opencode", AgentSessionRefKind::Id) => {
            vec!["opencode".into(), "--session".into(), session_ref.value.clone()]
        }
        ("qodercli", AgentSessionRefKind::Id) => {
            vec!["qodercli".into(), "--resume".into(), session_ref.value.clone()]
        }
        ("qwen", AgentSessionRefKind::Id) => {
            vec!["qwen".into(), "--resume".into(), session_ref.value.clone()]
        }
        ("kilo", AgentSessionRefKind::Id) => {
            vec!["kilo".into(), "--session".into(), session_ref.value.clone()]
        }
        ("cursor", AgentSessionRefKind::Id) => {
            vec![
                if cfg!(windows) { "cursor-agent.cmd" } else { "cursor-agent" }.into(),
                "--resume".into(),
                session_ref.value.clone(),
            ]
        }
        ("agy", AgentSessionRefKind::Id) => {
            vec!["agy".into(), "--conversation".into(), session_ref.value.clone()]
        }
        ("grok", AgentSessionRefKind::Id) => {
            vec!["grok".into(), "--resume".into(), session_ref.value.clone()]
        }
        _ => return None,
    };
    Some(AgentResumePlan {
        agent: agent.to_string(),
        argv,
        dedupe_key: dedupe_key(agent, session_ref),
    })
}

pub(crate) fn dedupe_key(agent: &str, session_ref: &AgentSessionRef) -> String {
    format!("{agent}\u{0}{:?}\u{0}{}", session_ref.kind, session_ref.value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_signals_resume_planner_maps_supported_agents_to_exact_argv() {
        let id = AgentSessionRef::id("session-1").unwrap();
        assert_eq!(plan("claude", &id).unwrap().argv, vec!["claude", "--resume", "session-1"]);
        assert_eq!(plan("codex", &id).unwrap().argv, vec!["codex", "resume", "session-1"]);
        assert_eq!(plan("copilot", &id).unwrap().argv, vec!["copilot", "--resume=session-1"]);
        assert_eq!(plan("agy", &id).unwrap().argv, vec!["agy", "--conversation", "session-1"]);
        assert_eq!(plan("opencode", &id).unwrap().argv, vec!["opencode", "--session", "session-1"]);
        assert_eq!(
            plan("hermes-agent", &id).unwrap().argv,
            vec!["hermes", "--resume", "session-1"]
        );
        assert!(plan("gemini", &id).is_none(), "no known resume interface");
        assert!(plan("amp", &id).is_none());
    }

    #[test]
    fn agent_signals_resume_refs_validate_as_data_not_shell_text() {
        assert!(AgentSessionRef::id("ok-id").is_some());
        assert!(AgentSessionRef::id("").is_none());
        assert!(AgentSessionRef::id("has\nnewline").is_none());
        assert!(AgentSessionRef::id("has\u{1b}escape").is_none());
        assert!(AgentSessionRef::id("x".repeat(513)).is_none());
        // Shell metacharacters stay inert: they ride inside one argv element.
        let hostile = AgentSessionRef::id("$(rm -rf /); id").unwrap();
        assert_eq!(
            plan("claude", &hostile).unwrap().argv,
            vec!["claude", "--resume", "$(rm -rf /); id"]
        );

        assert!(AgentSessionRef::path("/abs/path.jsonl").is_some());
        assert!(AgentSessionRef::path("relative/path.jsonl").is_none());
        assert!(AgentSessionRef::path("").is_none());
        assert!(AgentSessionRef::path(format!("/{}", "x".repeat(4096))).is_none());
    }

    #[test]
    fn agent_signals_resume_paths_resume_only_path_capable_agents() {
        let path = AgentSessionRef::path("/tmp/session.jsonl").unwrap();
        assert_eq!(plan("pi", &path).unwrap().argv, vec!["pi", "--session", "/tmp/session.jsonl"]);
        assert!(plan("claude", &path).is_none(), "claude resumes by id only");
        assert!(plan("codex", &path).is_none());
    }

    #[test]
    fn agent_signals_resume_dedupe_keys_distinguish_agent_kind_and_value() {
        let id = AgentSessionRef::id("s").unwrap();
        let path = AgentSessionRef::path("/s").unwrap();
        let keys: std::collections::HashSet<String> = [
            dedupe_key("claude", &id),
            dedupe_key("codex", &id),
            dedupe_key("pi", &id),
            dedupe_key("pi", &path),
        ]
        .into();
        assert_eq!(keys.len(), 4);
        assert_eq!(dedupe_key("claude", &id), dedupe_key("claude", &id));
    }
}
