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
    assert_eq!(name(&[("OPENCODE", "1")], None).as_deref(), Some("opencode@lawrences-macbook-pro"));
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

fn shown(vars: &[(&str, &str)], from: Option<&str>) -> Option<String> {
    sender(from, None, None, &with(vars), &mac).map(|s| s.shown().to_owned())
}

#[test]
fn the_chat_shows_the_app_and_the_persona_inside_it() {
    // u20190: "Grok bot › Ada", named by the sender; it overrides the environment.
    let grok = sender(Some("Grok bot › Ada"), None, None, &with(&[("CLAUDECODE", "1")]), &mac)
        .expect("an agent");
    assert_eq!((grok.name.as_str(), grok.shown()), ("Grok-bot.Ada", "Grok bot › Ada"));
    assert_eq!(shown(&[], Some("Muse")).as_deref(), Some("Muse"));
    assert_eq!(shown(&[], Some("Dot > Scout")).as_deref(), Some("Dot › Scout"));
    // Filled in where it can tell: the harness, its session and machine.
    let claude = [("CLAUDECODE", "1"), ("CLAUDE_CODE_SESSION_ID", "3fa9c1d2-77aa")];
    assert_eq!(
        shown(&claude, None).as_deref(),
        Some("Claude Code › 3fa9c1d2@lawrences-macbook-pro")
    );
    let lane = [("ACPMUX_SESSION_NAME", "lane-a"), ("CODEX_THREAD_ID", "019a")];
    assert_eq!(shown(&lane, None).as_deref(), Some("Codex › lane-a"));
    // An MCP client with no harness env names the app.
    let mcp = [(SENDER_APP_ENV, "Grok bot")];
    assert_eq!(shown(&mcp, None).as_deref(), Some("Grok bot › lawrences-macbook-pro"));
    assert_eq!(name(&mcp, None).as_deref(), Some("Grok-bot@lawrences-macbook-pro"));
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
