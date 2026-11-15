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
        settings_file: PathBuf::from("/home/.config/cmux/cmux-next.json"),
    }
}

/// An agent pooled under key `pooled`, then a chat that asks for key `asked`: the pool serves it
/// only when the keys match, and discards it otherwise.
fn served(pooled: PoolKey, asked: &PoolKey) -> bool {
    let mut pool: Pool<&'static str> = Pool::new(Duration::from_secs(600));
    let now = Duration::from_secs(1);
    let generation = pool.want(Role::Spare, pooled.clone(), now).start.expect("a start");
    assert!(pool.complete(&pooled, generation, "warm", now).is_none());
    match pool.take(asked) {
        Take::Ready(_) => true,
        Take::Discard(Some("warm")) => false,
        _ => panic!("the warm agent was neither served nor discarded"),
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
    let on = tool_servers(tools(r#"{"agents": {"cmuxMcp": "on"}}"#), &env, None);
    let off = tool_servers(tools(r#"{"agents": {"cmuxMcp": "off"}}"#), &env, None);
    assert_eq!(on, "cmux,answer:on");
    assert_eq!(off, "answer:off");
    // Through the pool: a spare started with `cmux` is discarded once the answer is off, and the
    // other way round; the same servers are served.
    let with = |servers: &str| PoolKey { tool_servers: servers.to_owned(), ..key(None) };
    assert!(!served(with(&on), &with(&off)));
    assert!(!served(with(&off), &with(&on)));
    assert!(served(with(&on), &with(&on)));
}

/// A pooled agent's `cmux` server was told to read the settings file of its start: a chat that
/// would read another file (the app now runs on its own file) never takes it.
#[test]
fn another_settings_file_leaves_a_pooled_key_unmatched() {
    let at = |file: &str| PoolKey { settings_file: PathBuf::from(file), ..key(None) };
    assert!(!served(at("/home/.config/cmux/cmux-next.json"), &at("/tmp/tagged/cmux-next.json")));
    assert!(served(at("/tmp/tagged/cmux-next.json"), &at("/tmp/tagged/cmux-next.json")));
}

/// A Codex spare started before the person added their own HTTP server named `cmux` to Codex's
/// config would still run cmux's server under that name: its key no longer matches.
#[test]
fn an_http_cmux_entry_leaves_a_pooled_codex_key_unmatched() {
    use std::os::unix::fs::PermissionsExt as _;
    let root = tempfile::tempdir().unwrap();
    let cmux = root.path().join("cmux");
    std::fs::write(&cmux, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o755)).unwrap();
    let (codex_home, work) = (root.path().join("codex-home"), root.path().join("work"));
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::create_dir_all(&work).unwrap();
    let tools = || {
        crate::agent_tools::resolve(&crate::agent_tools::Inputs {
            enabled: true,
            bin_dir: Some(root.path().to_owned()),
            cmux_json: Some(r#"{"agents": {"cmuxMcp": "on"}}"#.to_owned()),
            state_dir: root.path().join("state"),
            acpmux: None,
            secrets: false,
            offers: false,
            subsessions: false,
            displays: None,
            hosted: false,
        })
    };
    let env = std::collections::BTreeMap::from([(
        "CODEX_HOME".to_owned(),
        codex_home.to_string_lossy().into_owned(),
    )]);
    let argv = vec!["codex".to_owned(), "app-server".to_owned()];
    let codex = || Some(crate::agent_tools::CodexLaunch { cwd: &work, argv: &argv });
    let before = tool_servers(tools(), &env, codex());
    std::fs::write(
        codex_home.join("config.toml"),
        "[mcp_servers.cmux]\nurl = \"http://127.0.0.1:1/mcp\"\n",
    )
    .unwrap();
    let after = tool_servers(tools(), &env, codex());
    assert_eq!(before, "cmux,answer:on");
    assert_eq!(after, "answer:on");
    // Through the pool: the spare started before the entry is discarded, not served.
    let with = |servers: &str| PoolKey { tool_servers: servers.to_owned(), ..key(None) };
    assert!(!served(with(&before), &with(&after)));
    // Not Codex: the person's Codex config does not matter.
    assert_eq!(tool_servers(tools(), &env, None), "cmux,answer:on");
}

/// A Codex spare started before the person added their own stdio `cmux` entry got no env keys for
/// it (`agent_tools::person_entry_env`): once the entry is there, or the answer it would carry
/// changes, its key no longer matches and it is discarded.
#[test]
fn a_persons_stdio_cmux_entry_leaves_a_pooled_codex_key_unmatched() {
    let root = tempfile::tempdir().unwrap();
    let (codex_home, work) = (root.path().join("codex-home"), root.path().join("work"));
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::create_dir_all(&work).unwrap();
    let tools = || crate::agent_tools::AgentTools::default();
    let env = |answer: &str| {
        std::collections::BTreeMap::from([
            ("CODEX_HOME".to_owned(), codex_home.to_string_lossy().into_owned()),
            (crate::agent_tools::TOOLS_ANSWER_ENV.to_owned(), answer.to_owned()),
        ])
    };
    let argv = vec!["codex".to_owned(), "app-server".to_owned()];
    let codex = || Some(crate::agent_tools::CodexLaunch { cwd: &work, argv: &argv });
    let before = tool_servers(tools(), &env("off"), codex());
    std::fs::write(codex_home.join("config.toml"), "[mcp_servers.cmux]\ncommand = \"/opt/cmux\"\n")
        .unwrap();
    let off = tool_servers(tools(), &env("off"), codex());
    let on = tool_servers(tools(), &env("on"), codex());
    assert_eq!(before, "answer:off");
    assert!(off.starts_with("answer:off,cmux-entry-env:off,cmux-entry-cmd:"), "{off}");
    assert!(on.starts_with("answer:on,cmux-entry-env:on,cmux-entry-cmd:"), "{on}");
    let with = |servers: &str| PoolKey { tool_servers: servers.to_owned(), ..key(None) };
    assert!(!served(with(&before), &with(&off)));
    assert!(!served(with(&off), &with(&on)));
    // A session cut off from cmux's tools carries `off` whatever the answer: a spare started
    // without the cut-off is not served to one with it.
    let mut cut = env("on");
    cut.insert(crate::agent_tools::SWITCH_ENV.to_owned(), "0".to_owned());
    let cut_off = tool_servers(tools(), &cut, codex());
    assert!(cut_off.starts_with("answer:off,cmux-entry-env:off,cmux-entry-cmd:"), "{cut_off}");
    // Another command in the person's entry: another key, so the spare is not served.
    std::fs::write(
        codex_home.join("config.toml"),
        "[mcp_servers.cmux]\ncommand = \"/opt/other\"\n",
    )
    .unwrap();
    let moved = tool_servers(tools(), &env("off"), codex());
    assert!(!served(with(&off), &with(&moved)), "{off} / {moved}");
    assert!(!served(with(&on), &with(&cut_off)));
}

/// A Claude spare when no `cmux` server resolves (no cmux CLI here): its key still carries the
/// answer it started under, so one started before the answer changed is discarded.
#[test]
fn the_answer_is_in_the_key_when_no_cmux_server_resolves() {
    let none = crate::agent_tools::AgentTools { cmux_for_agents: true, ..Default::default() };
    let off_now = crate::agent_tools::AgentTools::default();
    let env = std::collections::BTreeMap::new();
    let (on, off) = (tool_servers(none, &env, None), tool_servers(off_now, &env, None));
    assert_eq!((on.as_str(), off.as_str()), ("answer:on", "answer:off"));
    let with = |servers: &str| PoolKey { tool_servers: servers.to_owned(), ..key(None) };
    assert!(!served(with(&on), &with(&off)));
}
