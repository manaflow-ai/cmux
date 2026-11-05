//! How a queued agent message can reach its recipient (issue 36496), so a
//! queued message to a terminal agent is never mistaken for delivered work.
//! Each line names what moves the message, from what the daemon knows of the
//! agent in the terminal (`agent.list`, the hook-reported adapter). It says
//! what can happen, not what did: the receipt (`deliveries[].state`) says
//! that.

use serde_json::{Value, json};

/// What carries messages to one recipient.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Capability {
    /// An acpmux session: the daemon's pump hands it over as a session prompt.
    AcpPrompt,
    /// Claude Code in a terminal: an idle session wakes for it (asyncRewake),
    /// a submitted prompt carries it. Only for the Claude cmux's wrapper
    /// started in that terminal, and only while the wake setting is on.
    ClaudeWake,
    /// Codex in a terminal: its shared app-server takes it as a turn (idle)
    /// or a steer (running); without that daemon, its next prompt or stop
    /// hook carries it. An idle Codex without the daemon waits.
    CodexAppServer,
    /// A terminal agent with no supported message path in cmux (Muse Code,
    /// OpenCode's terminal app, others): the message stays queued until
    /// someone reads it with `cmux agent inbox`. Nothing is typed into its
    /// terminal.
    Unsupported,
    /// No agent reported in the terminal (yet): the agent that starts there
    /// decides.
    Unknown,
}

impl Capability {
    /// The capability of `recipient` given the daemon's `agent.list`.
    pub(super) fn of(recipient: &str, agents: Option<&Value>) -> Self {
        if recipient.starts_with("acp:") {
            return Self::AcpPrompt;
        }
        let adapter = agents
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|agent| {
                agent.get("terminal_id").and_then(Value::as_str) == Some(recipient)
                    && agent.get("state").and_then(Value::as_str) != Some("done")
            })
            // Optional metadata: an entry without a string adapter names no
            // agent, so the terminal reads as unknown, never as supported.
            .filter_map(|agent| agent.pointer("/extra/agent").and_then(Value::as_str))
            .next();
        match adapter {
            Some("claude") => Self::ClaudeWake,
            Some("codex") => Self::CodexAppServer,
            Some(_) => Self::Unsupported,
            None => Self::Unknown,
        }
    }

    pub(super) fn wire(self) -> &'static str {
        match self {
            Self::AcpPrompt => "acp_prompt",
            Self::ClaudeWake => "claude_wake",
            Self::CodexAppServer => "codex_app_server",
            Self::Unsupported => "unsupported",
            Self::Unknown => "unknown",
        }
    }

    /// One sentence on how a queued message reaches the agent.
    pub(super) fn text(self) -> &'static str {
        match self {
            Self::AcpPrompt => "the daemon hands it to the session as a prompt",
            Self::ClaudeWake => {
                "an idle Claude wakes for it and a submitted prompt carries it (Claude started \
                 through cmux, with Agent Messages on)"
            }
            Self::CodexAppServer => {
                "Codex takes it as a turn or a steer through its shared app-server, else at its \
                 next prompt or stop"
            }
            Self::Unsupported => {
                "this agent has no supported message delivery in cmux; it stays queued until read \
                 with `cmux agent inbox`"
            }
            Self::Unknown => "no agent reported in this terminal yet",
        }
    }
}

/// `{recipient: {"capability": wire, "text": text}}` for every recipient.
pub(super) fn capabilities(recipients: &[String], agents: Option<&Value>) -> Value {
    let mut map = serde_json::Map::new();
    for recipient in recipients {
        let capability = Capability::of(recipient, agents);
        map.insert(
            recipient.clone(),
            json!({"capability": capability.wire(), "text": capability.text()}),
        );
    }
    Value::Object(map)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

    fn agents(adapter: &str, state: &str) -> Value {
        json!([{"terminal_id": TERMINAL, "state": state, "extra": {"agent": adapter}}])
    }

    /// Issue 36496: each recipient says what can carry a queued message, and
    /// a terminal agent with no supported path says so instead of implying
    /// delivery.
    #[test]
    fn each_recipient_reports_what_can_carry_its_messages() {
        assert_eq!(Capability::of("acp:s1", None), Capability::AcpPrompt);
        assert_eq!(
            Capability::of(TERMINAL, Some(&agents("claude", "idle"))),
            Capability::ClaudeWake
        );
        assert_eq!(
            Capability::of(TERMINAL, Some(&agents("codex", "working"))),
            Capability::CodexAppServer
        );
        for unsupported in ["muse", "opencode", "gemini"] {
            let capability = Capability::of(TERMINAL, Some(&agents(unsupported, "idle")));
            assert_eq!(capability, Capability::Unsupported, "{unsupported}");
            assert!(capability.text().contains("no supported message delivery"));
        }
        // An ended agent is not the terminal's agent any more.
        assert_eq!(Capability::of(TERMINAL, Some(&agents("claude", "done"))), Capability::Unknown);
        assert_eq!(Capability::of(TERMINAL, None), Capability::Unknown);
        let map = capabilities(&[TERMINAL.to_owned()], Some(&agents("muse", "idle")));
        assert_eq!(map[TERMINAL]["capability"], "unsupported");
    }

    /// The adapter is optional metadata a hook reported: an entry with no
    /// `extra`, a non-object `extra`, a non-string adapter, or a non-string
    /// terminal or state names no agent. The terminal reads as unknown,
    /// never as a supported path, and nothing panics.
    #[test]
    fn malformed_agent_metadata_reports_unknown() {
        for agents in [
            json!([{"terminal_id": TERMINAL, "state": "idle"}]),
            json!([{"terminal_id": TERMINAL, "state": "idle", "extra": "claude"}]),
            json!([{"terminal_id": TERMINAL, "state": "idle", "extra": {"agent": 7}}]),
            json!([{"terminal_id": 7, "state": "idle", "extra": {"agent": "claude"}}]),
            json!(["claude", null, 3]),
            json!({"terminal_id": TERMINAL}),
        ] {
            assert_eq!(Capability::of(TERMINAL, Some(&agents)), Capability::Unknown, "{agents}");
        }
        // A non-string state is not "done": the reported adapter still counts.
        let odd_state = json!([{"terminal_id": TERMINAL, "state": 1, "extra": {"agent": "codex"}}]);
        assert_eq!(Capability::of(TERMINAL, Some(&odd_state)), Capability::CodexAppServer);
    }
}
