//! Who an agent's chat message is from (u19922, Nov 3: "ensure that one can
//! communicate with the chief/any chief/other humans in cmux chat, via the
//! CLI/mcp"). Every agent send (`cmux chief -p`, `cmux chief send`, `cmux chat
//! send`, the MCP `chat_send` tool) names its sender with this one rule, so a
//! coding agent in any terminal is read as that agent, never as the owner:
//!
//! 1. `--from`/`--as NAME`, else `ACPMUX_SESSION_NAME` (every acpmux agent;
//!    the name the Chief's reply route sends back to), else `CMUX_AGENT_NAME`.
//! 2. Else the harness the process runs under (Claude Code, Codex, OpenCode,
//!    pi, or any `AI_AGENT`), as `<harness>-<session>@<host>`: the session id's
//!    first 8 characters and this machine's short host name, so a reader can
//!    tell two Claudes on two Macs apart.
//!
//! None means the person at a terminal: their message stays theirs.

use cmux_conversation::agent_sender::AgentSender;

/// The harnesses known by their environment, each with the variables that
/// mark it (any non-empty one) and the ones that carry its session id.
const HARNESSES: [(&str, &[&str], &[&str]); 4] = [
    (
        "claude",
        &["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"],
        &["CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID"],
    ),
    (
        "codex",
        &[
            "CODEX_THREAD_ID",
            "CODEX_SESSION_ID",
            "CODEX_SANDBOX",
            "CODEX_CI",
            "CODEX_MANAGED_BY_NPM",
        ],
        &["CODEX_THREAD_ID", "CODEX_SESSION_ID"],
    ),
    ("opencode", &["OPENCODE", "OPENCODE_SESSION_ID", "OPENCODE_PORT"], &["OPENCODE_SESSION_ID"]),
    ("pi", &["PI_CODING_AGENT", "PI_SESSION_ID"], &["PI_SESSION_ID"]),
];

/// The sender of an agent's message (rule in the module doc); None for the
/// person. `env` reads one variable, `host` this machine's name.
pub(in crate::cli) fn sender(
    from: Option<&str>,
    class: Option<&str>,
    thread: Option<&str>,
    env: &dyn Fn(&str) -> Option<String>,
    host: &dyn Fn() -> Option<String>,
) -> Option<AgentSender> {
    let set = |key: &str| env(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
    let named = from
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .map(str::to_owned)
        .or_else(|| set("ACPMUX_SESSION_NAME"))
        .or_else(|| set("CMUX_AGENT_NAME"));
    if let Some(name) = named {
        return AgentSender::new(&name, class, thread);
    }
    let harness = HARNESSES
        .iter()
        .find(|(_, marks, _)| marks.iter().any(|key| set(key).is_some()))
        .map(|(name, _, sessions)| ((*name).to_owned(), sessions.iter().find_map(|k| set(k))))
        .or_else(|| set("AI_AGENT").map(|agent| (agent, None)))?;
    let (harness, session) = harness;
    let mut name = harness;
    if let Some(session) = session {
        let short: String = session.chars().filter(char::is_ascii_alphanumeric).take(8).collect();
        if !short.is_empty() {
            name = format!("{name}-{short}");
        }
    }
    if let Some(host) = host() {
        let short = host.split('.').next().unwrap_or("").trim().to_ascii_lowercase();
        if !short.is_empty() {
            name = format!("{name}@{short}");
        }
    }
    AgentSender::new(&name, class, thread)
}

/// [`sender`] for this process: its environment and host name.
pub(in crate::cli) fn current(
    from: Option<&str>,
    class: Option<&str>,
    thread: Option<&str>,
) -> Option<AgentSender> {
    sender(from, class, thread, &|key| std::env::var(key).ok(), &host_name)
}

/// This machine's host name (`gethostname`), None when it has none.
pub(in crate::cli) fn host_name() -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is valid for its whole length; gethostname writes at
    // most that many bytes and the result is read only up to the first NUL.
    let status = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if status != 0 {
        return None;
    }
    let end = buffer.iter().position(|b| *b == 0).unwrap_or(buffer.len());
    let name = String::from_utf8_lossy(&buffer[..end]).trim().to_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let vars: Vec<(String, String)> =
            vars.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        move |key| vars.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
    }

    fn mac() -> Option<String> {
        Some("Lawrences-MacBook-Pro.local".into())
    }

    fn name(vars: &[(&str, &str)], from: Option<&str>) -> Option<String> {
        sender(from, None, None, &with(vars), &mac).map(|s| s.name)
    }

    #[test]
    fn a_claude_code_terminal_is_an_agent_named_by_session_and_machine() {
        let vars = [("CLAUDECODE", "1"), ("CLAUDE_CODE_SESSION_ID", "3fa9c1d2-77aa-4c1e")];
        assert_eq!(name(&vars, None).as_deref(), Some("claude-3fa9c1d2@lawrences-macbook-pro"));
    }

    #[test]
    fn a_codex_opencode_and_pi_session_are_agents_too() {
        let codex = [("CODEX_THREAD_ID", "019a2b3c-dead-beef")];
        assert_eq!(name(&codex, None).as_deref(), Some("codex-019a2b3c@lawrences-macbook-pro"));
        assert_eq!(
            name(&[("OPENCODE", "1")], None).as_deref(),
            Some("opencode@lawrences-macbook-pro")
        );
        assert_eq!(
            name(&[("PI_CODING_AGENT", "1")], None).as_deref(),
            Some("pi@lawrences-macbook-pro")
        );
        assert_eq!(
            name(&[("AI_AGENT", "goose")], None).as_deref(),
            Some("goose@lawrences-macbook-pro")
        );
    }

    #[test]
    fn an_acpmux_session_keeps_its_own_name_so_replies_route_back() {
        let vars = [("ACPMUX_SESSION_NAME", "lane-a"), ("CLAUDECODE", "1")];
        assert_eq!(name(&vars, None).as_deref(), Some("lane-a"));
        assert_eq!(name(&vars, Some("reviewer")).as_deref(), Some("reviewer"));
        assert_eq!(name(&[("CMUX_AGENT_NAME", "a12")], None).as_deref(), Some("a12"));
    }

    #[test]
    fn the_person_at_a_plain_terminal_is_no_agent() {
        assert_eq!(name(&[("HOME", "/Users/me"), ("CLAUDECODE", "")], None), None);
    }

    #[test]
    fn the_class_and_thread_carry_through() {
        let sender =
            sender(None, Some("question"), Some("pr:1"), &with(&[("OPENCODE", "1")]), &|| None)
                .expect("an agent");
        assert_eq!((sender.name.as_str(), sender.class.as_str()), ("opencode", "question"));
        assert_eq!(sender.thread.as_deref(), Some("pr:1"));
    }
}
