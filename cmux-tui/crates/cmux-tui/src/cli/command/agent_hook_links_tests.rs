//! `agent hook` link rows: ids, the states the Settings card reads, and what a run changes.

use std::path::Path;

use acpmux::desktop_link::{App, Env};
use serde_json::json;

use super::*;
use crate::agent_hook_install::Action;

/// A scratch home where Claude desktop and Codex are installed, and Claude Code is not.
fn env(dir: &Path) -> Env {
    let env = Env {
        home: dir.to_path_buf(),
        claude_config_dir: None,
        codex_home: None,
        xdg_config_home: None,
        exe: PathBuf::from("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"),
        args: vec!["acp".to_owned(), "acpmux-mcp".to_owned()],
        acpmux_home: Some(dir.join(".acpmux")),
        claude_cli: None,
    };
    std::fs::create_dir_all(env.config_path(App::ClaudeDesktop).parent().unwrap()).unwrap();
    std::fs::create_dir_all(env.config_path(App::Codex).parent().unwrap()).unwrap();
    env
}

#[test]
fn link_ids_are_split_from_hook_ids() {
    let ids: Vec<String> =
        ["claude", "link-codex", "link-claude-desktop", "link-codex", "link-chat"]
            .map(String::from)
            .into();
    let (apps, hooks, errors) = split(&ids);
    assert_eq!(apps, [App::Codex, App::ClaudeDesktop]);
    assert_eq!(hooks, ["claude"]);
    assert_eq!(errors.len(), 1);
    assert!(errors[0].starts_with("link-chat: "), "{errors:?}");
    assert_eq!(id(App::ClaudeCode), "link-claude-code");
}

#[test]
fn status_lists_the_apps_here_in_the_cards_states() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path());
    let (rows, errors) = run_in(&env, Action::Status, &App::ALL);
    assert!(errors.is_empty(), "{errors:?}");
    // Claude Code is not here: no row.
    let ids: Vec<&str> = rows.iter().filter_map(|r| r["provider"].as_str()).collect();
    assert_eq!(ids, ["link-claude-desktop", "link-codex"]);
    assert!(rows.iter().all(|r| r["state"] == "absent"), "{rows:?}");
}

#[test]
fn connect_then_disconnect_writes_and_removes_the_entry() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path());
    let (rows, errors) = run_in(&env, Action::Install, &[App::Codex]);
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(rows[0]["state"], "installed");
    assert_eq!(rows[0]["changed"], true);
    let config = std::fs::read_to_string(env.config_path(App::Codex)).unwrap();
    assert!(config.contains("[mcp_servers.cmux]"), "{config}");
    assert!(config.contains("ACPMUX_MCP_GUEST"), "{config}");

    let (rows, _) = run_in(&env, Action::Status, &[App::Codex]);
    assert_eq!(rows[0]["state"], "installed");
    let (rows, errors) = run_in(&env, Action::Uninstall, &[App::Codex]);
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(rows[0]["state"], "absent");
    assert!(
        !std::fs::read_to_string(env.config_path(App::Codex)).unwrap().contains("mcp_servers.cmux")
    );
}

#[test]
fn another_builds_entry_needs_repair_and_a_foreign_one_is_a_conflict() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path());
    run_in(&env, Action::Install, &[App::ClaudeDesktop]);
    env.exe = PathBuf::from("/Applications/cmux NEXT DEV.app/Contents/Resources/bin/cmux");
    let (rows, _) = run_in(&env, Action::Status, &[App::ClaudeDesktop]);
    assert_eq!(rows[0]["state"], "partial");

    let mine = r#"{"mcpServers": {"cmux": {"command": "/usr/local/bin/my-cmux"}}}"#;
    std::fs::write(env.config_path(App::ClaudeDesktop), mine).unwrap();
    let (rows, _) = run_in(&env, Action::Status, &[App::ClaudeDesktop]);
    assert_eq!(
        (rows[0]["state"].as_str(), rows[0]["reason"].as_str()),
        (Some("conflict"), Some("not_owned"))
    );
    let (_, errors) = run_in(&env, Action::Install, &[App::ClaudeDesktop]);
    assert!(errors[0].starts_with("link-claude-desktop: "), "{errors:?}");
    assert!(errors[0].contains("left alone"), "{errors:?}");
    assert_eq!(std::fs::read_to_string(env.config_path(App::ClaudeDesktop)).unwrap(), mine);
}

#[test]
fn an_unreadable_config_is_unavailable_and_an_absent_app_is_named() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path());
    std::fs::write(env.config_path(App::ClaudeDesktop), "{ not json").unwrap();
    let (rows, _) = run_in(&env, Action::Status, &[App::ClaudeDesktop]);
    assert_eq!(
        (rows[0]["state"].as_str(), rows[0]["reason"].as_str()),
        (Some("unavailable"), Some("unreadable"))
    );

    let (rows, errors) = run_in(&env, Action::Install, &[App::ClaudeCode]);
    assert!(rows.is_empty());
    assert_eq!(errors, ["link-claude-code: Claude Code is not installed here"]);
}

#[test]
fn link_rows_join_the_hook_answer() {
    let hooks = json!({"action": "status", "providers": [{"provider": "claude"}], "errors": []});
    let merged = merge(hooks, vec![json!({"provider": "link-codex"})], vec!["link-x: no".into()]);
    assert_eq!(merged["providers"], json!([{"provider": "claude"}, {"provider": "link-codex"}]));
    assert_eq!(merged["errors"], json!(["link-x: no"]));
}
