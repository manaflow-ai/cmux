//! A pooled Claude or Codex agent read `agents.promptSuggestions` once as its host started: a
//! change since (the settings file, or what MDM or the team policy forces) leaves its key
//! unmatched, so a new chat never takes an agent under the old switch (review F2 of cmux#33097).

use super::*;

fn profile(kind: &str, argv: &[&str]) -> HarnessProfile {
    serde_json::from_value(json!({"kind": kind, "argv": argv})).expect("profile")
}

fn key(prompt_suggestions: Option<bool>) -> PoolKey {
    PoolKey {
        origin: Origin::Local,
        cwd: PathBuf::from("/a"),
        harness: "claude".into(),
        preset: None,
        args: Vec::new(),
        system_prompt_sha256: None,
        auth: String::new(),
        account: None,
        machine: None,
        prompt_suggestions,
        tool_servers: String::new(),
    }
}

#[test]
fn only_harnesses_that_read_the_switch_carry_it_in_their_key() {
    let claude = profile("claude-stdio", &["claude"]);
    let codex = profile("acp", &["codex", "app-server"]);
    let opencode = profile("acp", &["opencode", "acp"]);
    assert_eq!(suggestions_at_start(&claude, || false), Some(false));
    assert_eq!(suggestions_at_start(&codex, || true), Some(true));
    assert_eq!(suggestions_at_start(&opencode, || panic!("opencode reads no switch")), None);
}

#[test]
fn an_agent_pooled_under_the_old_switch_is_discarded_not_served() {
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let now = Duration::from_secs(1);
    let on = key(Some(true));
    let generation = pool.want(Role::Spare, on.clone(), now).start.expect("a start");
    assert!(pool.complete(&on, generation, "warm-on", now).is_none());
    match pool.take(&key(Some(false))) {
        Take::Discard(Some("warm-on")) => {}
        Take::Ready(p) => panic!("served {p} under the old switch"),
        _ => panic!("the warm agent was neither served nor discarded"),
    }
}

/// A pooled agent was given its tool servers as it started: once the person turns cmux's tools
/// for agents on or off (`agents.cmuxMcp`), a session of the same shape asks for other servers, so
/// the old entry's key no longer matches and it is never served with the old `cmux` server.
#[test]
fn a_change_to_cmux_tools_leaves_a_pooled_key_unmatched() {
    use std::os::unix::fs::PermissionsExt as _;
    let root = tempfile::tempdir().unwrap();
    let cmux = root.path().join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    let tools = |json: &str| {
        crate::agent_tools::resolve(&crate::agent_tools::Inputs {
            enabled: true,
            bin_dir: Some(root.path().to_owned()),
            cmux_json: Some(json.to_owned()),
            state_dir: root.path().join("state"),
            acpmux: None,
            secrets: false,
            offers: false,
            subsessions: false,
            displays: None,
            hosted: false,
        })
    };
    let env = std::collections::BTreeMap::new();
    let on = tool_servers(tools(r#"{"agents": {"cmuxMcp": "on"}}"#), &env);
    let off = tool_servers(tools(r#"{"agents": {"cmuxMcp": "off"}}"#), &env);
    assert_eq!(on, "cmux");
    assert_eq!(off, "");
    assert_ne!(key(None), PoolKey { tool_servers: on, ..key(None) });
}
