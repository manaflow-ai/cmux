use super::*;
use serde_json::json;

fn profile(kind: HarnessKind, argv: &[&str]) -> HarnessProfile {
    let mut p: HarnessProfile = serde_json::from_value(json!({"argv": argv})).unwrap();
    p.kind = kind;
    p
}

#[test]
fn unset_keys_change_nothing() {
    let doc = json!({"agents": {"promptCache": "1h"}});
    let launch = Launch::read(&doc, Provider::Claude);
    assert_eq!(launch, Launch::default());
    let mut p = profile(HarnessKind::ClaudeStdio, &["/usr/bin/claude"]);
    let before = p.clone();
    launch.apply(&mut p, Provider::Claude);
    assert_eq!(p, before);
}

#[test]
fn claude_path_home_args_env_apply_to_the_builtin_launch() {
    let doc = json!({"agents": {"providers": {"claude": {
        "path": " ~/bin/claude-beta ",
        "home": "~/.claude-work",
        "args": ["--verbose", ""],
        "env": {"DISABLE_TELEMETRY": "1", "bad name": "x", "N": 3}
    }}}});
    let launch = Launch::read(&doc, Provider::Claude);
    let mut p = profile(HarnessKind::ClaudeStdio, &["/usr/bin/claude"]);
    launch.apply(&mut p, Provider::Claude);
    assert_eq!(p.argv, ["~/bin/claude-beta", "--verbose"]);
    assert_eq!(p.env.get("CLAUDE_CONFIG_DIR").map(String::as_str), Some("~/.claude-work"));
    assert_eq!(p.env.get("DISABLE_TELEMETRY").map(String::as_str), Some("1"));
    assert_eq!(p.env.len(), 2, "an invalid name and a non-text value are left out");
}

#[test]
fn flat_dotted_keys_read_too() {
    let doc =
        json!({"agents.providers.codex.path": "/opt/codex", "agents.providers.codex.home": "/w"});
    let launch = Launch::read(&doc, Provider::Codex);
    assert_eq!(launch.path.as_deref(), Some("/opt/codex"));
    assert_eq!(launch.home.as_deref(), Some("/w"));
}

#[test]
fn codex_path_is_the_bridges_codex_path_and_home_is_codex_home() {
    let doc = json!({"agents": {"providers": {"codex": {
        "path": "/opt/codex", "home": "/h/.codex-work", "args": ["-c", "x=1"]
    }}}});
    let mut p = profile(HarnessKind::Acp, &["/usr/bin/codex", "app-server"]);
    p.env.insert("CODEX_PATH".into(), "/from/defaults".into());
    Launch::read(&doc, Provider::Codex).apply(&mut p, Provider::Codex);
    assert_eq!(p.argv, ["/usr/bin/codex", "app-server", "-c", "x=1"]);
    assert_eq!(p.env.get("CODEX_PATH").map(String::as_str), Some("/opt/codex"));
    assert_eq!(p.env.get("CODEX_HOME").map(String::as_str), Some("/h/.codex-work"));
}

#[test]
fn only_builtin_claude_and_codex_launches_take_the_settings() {
    let claude = profile(HarnessKind::ClaudeStdio, &["/usr/bin/claude"]);
    let sr = profile(HarnessKind::ClaudeStdio, &["/usr/bin/sr", "claude", "proxy"]);
    let codex = profile(HarnessKind::Acp, &["/usr/bin/codex", "app-server"]);
    let adapter = profile(HarnessKind::Acp, &["/usr/bin/codex-acp"]);
    let gemini = profile(HarnessKind::Acp, &["/usr/bin/gemini", "--experimental-acp"]);
    assert_eq!(Provider::of_builtin(&claude, true), Some(Provider::Claude));
    assert_eq!(Provider::of_builtin(&codex, true), Some(Provider::Codex));
    assert_eq!(Provider::of_builtin(&sr, true), None);
    assert_eq!(Provider::of_builtin(&adapter, true), None);
    assert_eq!(Provider::of_builtin(&gemini, true), None);
    assert_eq!(Provider::of_builtin(&claude, false), None, "a person's own profile keeps its own");
    assert_eq!(Provider::of_builtin(&codex, false), None);
}
