use super::layered;
use std::collections::BTreeMap;

fn pairs(list: &[(&str, &str)]) -> Vec<(String, String)> {
    list.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// A sign-in check reads what the agent would get (hq#2569 #2): a token or
/// a `CODEX_HOME` exported only in the login shell counts, the profile's
/// env wins, and a nested Claude Code session's keys do not leak in.
#[test]
fn layers_daemon_login_and_profile_like_a_spawn() {
    let profile = BTreeMap::from([("CODEX_HOME".to_owned(), "/profile/codex".to_owned())]);
    let env = layered(
        pairs(&[("HOME", "/u"), ("CODEX_HOME", "/daemon/codex"), ("OPENAI_BASE_URL", "d")]),
        false,
        pairs(&[("CLAUDE_CODE_OAUTH_TOKEN", "login"), ("OPENAI_BASE_URL", "login")]),
        Vec::new(),
        &profile,
    );
    assert_eq!(env["HOME"], "/u");
    assert_eq!(env["CODEX_HOME"], "/profile/codex");
    assert_eq!(env["OPENAI_BASE_URL"], "login");
    assert_eq!(env["CLAUDE_CODE_OAUTH_TOKEN"], "login");

    let nested = layered(
        pairs(&[("CLAUDECODE", "1"), ("ANTHROPIC_API_KEY", "session"), ("HOME", "/u")]),
        true,
        Vec::new(),
        pairs(&[("CLAUDE_CODE_OAUTH_TOKEN", "login")]),
        &BTreeMap::new(),
    );
    assert!(!nested.contains_key("ANTHROPIC_API_KEY"));
    assert_eq!(nested["CLAUDE_CODE_OAUTH_TOKEN"], "login");
    assert_eq!(nested["HOME"], "/u");
}

/// Under a nested Claude Code session the scrub drops the vault's and
/// `machine.env`'s Claude keys too; a launch puts them back
/// (`restore_machine_tokio`) and a sign-in check must see the same:
/// session over machine over vault over login over the daemon.
#[test]
fn a_nested_check_restores_the_vault_and_machine_like_a_launch() {
    let vault = pairs(&[("ANTHROPIC_BASE_URL", "vault"), ("ANTHROPIC_MODEL", "vault")]);
    let machine = BTreeMap::from([("ANTHROPIC_MODEL".to_owned(), "machine".to_owned())]);
    let login = BTreeMap::from([
        ("ANTHROPIC_BASE_URL".to_owned(), "login".to_owned()),
        ("ANTHROPIC_SMALL_FAST_MODEL".to_owned(), "login".to_owned()),
    ]);
    let mut restored = pairs(&[("ANTHROPIC_SMALL_FAST_MODEL", "login")]);
    restored.extend(super::nested_local(vault.clone(), machine.clone()));
    let profile = BTreeMap::from([("ANTHROPIC_MODEL".to_owned(), "session".to_owned())]);
    let env = layered(
        pairs(&[("CLAUDECODE", "1"), ("ANTHROPIC_BASE_URL", "daemon"), ("HOME", "/u")]),
        true,
        super::overlay(login, vault, machine.clone()),
        restored,
        &profile,
    );
    assert_eq!(env["ANTHROPIC_BASE_URL"], "vault");
    assert_eq!(env["ANTHROPIC_SMALL_FAST_MODEL"], "login");
    assert_eq!(env["ANTHROPIC_MODEL"], "session");
    let env = layered(
        pairs(&[("CLAUDECODE", "1")]),
        true,
        Vec::new(),
        super::nested_local(pairs(&[("ANTHROPIC_MODEL", "vault")]), machine),
        &BTreeMap::new(),
    );
    assert_eq!(env["ANTHROPIC_MODEL"], "machine");
}
