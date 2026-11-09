//! `acpmux desktop link`: each app's entry over a scratch home.

use super::*;

/// A scratch home where Claude desktop and Codex are installed (their config folders exist) and
/// Claude Code's CLI is `claude_cli`.
fn env(dir: &Path, claude_cli: Option<PathBuf>) -> Env {
    let env = Env {
        home: dir.to_path_buf(),
        claude_config_dir: None,
        codex_home: None,
        xdg_config_home: None,
        exe: PathBuf::from("/opt/cmux/bin/acpmux"),
        args: vec!["acpmux-mcp".to_owned()],
        acpmux_home: None,
        claude_cli,
    };
    std::fs::create_dir_all(env.config_path(App::ClaudeDesktop).parent().unwrap()).unwrap();
    std::fs::create_dir_all(env.config_path(App::Codex).parent().unwrap()).unwrap();
    env
}

#[test]
fn every_app_has_an_id_the_cli_takes_back() {
    for app in App::ALL {
        assert_eq!(App::parse(app.id()), Some(app));
    }
    assert_eq!(apps(None).unwrap(), App::ALL.to_vec());
    assert_eq!(apps(Some("codex")).unwrap(), vec![App::Codex]);
    assert!(
        apps(Some("chat")).unwrap_err().to_string().contains("claude-desktop, claude-code, codex")
    );
}

#[test]
fn claude_desktop_gets_the_entry_beside_the_persons_own_servers() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    std::fs::write(
        &path,
        r#"{"mcpServers": {"files": {"command": "npx", "args": ["fs"]}}, "globalShortcut": "Alt+Space"}"#,
    )
    .unwrap();
    assert_eq!(status(&env, App::ClaudeDesktop).state, State::NotLinked);
    let dry = link(&env, App::ClaudeDesktop, true);
    assert_eq!((dry.state, dry.note.as_deref()), (State::NotLinked, Some("would link")));

    let row = link(&env, App::ClaudeDesktop, false);
    assert_eq!(row.state, State::Linked, "{:?}", row.note);
    assert!(row.note.unwrap().contains("reopen Claude desktop"));
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(doc["globalShortcut"], "Alt+Space");
    assert_eq!(doc["mcpServers"]["files"]["command"], "npx");
    let entry = &doc["mcpServers"]["cmux"];
    assert_eq!(entry["command"], "/opt/cmux/bin/acpmux");
    assert_eq!(entry["args"], json!(["acpmux-mcp"]));
    assert_eq!(entry["env"][GUEST_ENV], "claude-desktop");
    assert_eq!(link(&env, App::ClaudeDesktop, false).note.as_deref(), Some("already linked"));

    let row = unlink(&env, App::ClaudeDesktop, false);
    assert_eq!(row.state, State::NotLinked);
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(doc["mcpServers"].get("cmux").is_none());
    assert_eq!(doc["mcpServers"]["files"]["command"], "npx");
}

#[test]
fn claude_desktop_keeps_the_persons_key_order() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    std::fs::write(
        &path,
        r#"{"zoom": 1, "mcpServers": {"zeta": {"command": "z"}, "files": {"command": "f"}}, "alpha": true}"#,
    )
    .unwrap();
    let at = |text: &str, key: &str| text.find(&format!("\"{key}\"")).unwrap();
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(at(&text, "zoom") < at(&text, "mcpServers"), "{text}");
    assert!(at(&text, "mcpServers") < at(&text, "alpha"), "{text}");
    assert!(at(&text, "zeta") < at(&text, "files"), "{text}");
    assert!(at(&text, "files") < at(&text, "cmux"), "{text}");

    assert_eq!(unlink(&env, App::ClaudeDesktop, false).state, State::NotLinked);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(!text.contains("\"cmux\""), "{text}");
    assert!(at(&text, "zoom") < at(&text, "mcpServers"), "{text}");
    assert!(at(&text, "zeta") < at(&text, "files"), "{text}");
    let doc: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        doc,
        json!({"zoom": 1, "mcpServers": {"zeta": {"command": "z"}, "files": {"command": "f"}}, "alpha": true})
    );
}

#[test]
fn the_cmux_binary_runs_the_server_under_its_acp_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    let me = crate::self_command::SelfCommand::new(
        PathBuf::from("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"),
        vec!["acp".into()],
    );
    env.args = me.args_lossy(&["acpmux-mcp"]);
    env.exe = me.exe;
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    let doc: toml::Table =
        toml::from_str(&std::fs::read_to_string(env.config_path(App::Codex)).unwrap()).unwrap();
    let args: Vec<&str> = doc["mcp_servers"]["cmux"]["args"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|a| a.as_str())
        .collect();
    assert_eq!(args, ["acp", "acpmux-mcp"]);
    // The same binary under its own name has no prefix: that entry is another binary's.
    env.args = vec!["acpmux-mcp".to_owned()];
    assert_eq!(status(&env, App::Codex).state, State::Stale);
}

#[test]
fn a_missing_config_file_is_made_with_only_the_entry() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    let doc: Value = serde_json::from_str(
        &std::fs::read_to_string(env.config_path(App::ClaudeDesktop)).unwrap(),
    )
    .unwrap();
    assert_eq!(doc["mcpServers"].as_object().unwrap().len(), 1);
}

#[test]
fn an_entry_cmux_did_not_write_is_never_replaced_or_removed() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    let mine = r#"{"mcpServers": {"cmux": {"command": "/usr/local/bin/my-cmux", "args": []}}}"#;
    std::fs::write(&path, mine).unwrap();
    assert_eq!(status(&env, App::ClaudeDesktop).state, State::Foreign);
    let row = link(&env, App::ClaudeDesktop, false);
    assert_eq!(row.state, State::Foreign);
    assert!(row.note.unwrap().contains("left alone"));
    assert_eq!(unlink(&env, App::ClaudeDesktop, false).state, State::Foreign);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), mine);
}

#[test]
fn an_entry_of_ours_for_another_binary_is_stale_and_relinked() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    env.exe = PathBuf::from("/Applications/cmux NEXT.app/Contents/Resources/bin/acpmux");
    assert_eq!(status(&env, App::ClaudeDesktop).state, State::Stale);
    assert_eq!(link(&env, App::ClaudeDesktop, false).state, State::Linked);
    let doc: Value = serde_json::from_str(
        &std::fs::read_to_string(env.config_path(App::ClaudeDesktop)).unwrap(),
    )
    .unwrap();
    assert_eq!(doc["mcpServers"]["cmux"]["command"], env.exe.to_string_lossy().as_ref());
}

/// Review F4 (#39320): an entry for another acpmux home reaches another daemon, so it is stale
/// and link points it at this one.
#[test]
fn an_entry_for_another_acpmux_home_is_stale_and_relinked() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    env.acpmux_home = Some(PathBuf::from("/tmp/acpmux-a"));
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    env.acpmux_home = Some(PathBuf::from("/tmp/acpmux-b"));
    assert_eq!(status(&env, App::Codex).state, State::Stale);
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    let doc: toml::Table =
        toml::from_str(&std::fs::read_to_string(env.config_path(App::Codex)).unwrap()).unwrap();
    assert_eq!(doc["mcp_servers"]["cmux"]["env"]["ACPMUX_HOME"].as_str(), Some("/tmp/acpmux-b"));
    env.acpmux_home = None;
    assert_eq!(status(&env, App::Codex).state, State::Stale);
}

#[test]
fn codex_gets_a_table_and_keeps_the_persons_comments_and_order() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), None);
    env.acpmux_home = Some(PathBuf::from("/tmp/acpmux-dev"));
    let path = env.config_path(App::Codex);
    let before =
        "# my settings\nmodel = \"gpt-5.5\"\n\n[mcp_servers.docs]\ncommand = \"docs-mcp\" # mine\n";
    std::fs::write(&path, before).unwrap();
    assert_eq!(status(&env, App::Codex).state, State::NotLinked);
    assert_eq!(link(&env, App::Codex, false).state, State::Linked);
    let after = std::fs::read_to_string(&path).unwrap();
    assert!(after.starts_with(before), "{after}");
    let doc: toml::Table = toml::from_str(&after).unwrap();
    let entry = &doc["mcp_servers"]["cmux"];
    assert_eq!(entry["command"].as_str(), Some("/opt/cmux/bin/acpmux"));
    assert_eq!(entry["env"][GUEST_ENV].as_str(), Some("codex"));
    assert_eq!(entry["env"]["ACPMUX_HOME"].as_str(), Some("/tmp/acpmux-dev"));
    assert_eq!(status(&env, App::Codex).state, State::Linked);

    assert_eq!(unlink(&env, App::Codex, false).state, State::NotLinked);
    let doc: toml::Table = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(doc["mcp_servers"].get("cmux").is_none());
    assert_eq!(doc["mcp_servers"]["docs"]["command"].as_str(), Some("docs-mcp"));
    // Unlink takes back exactly what link wrote.
    assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
}

#[test]
fn an_app_that_is_not_here_is_not_linked() {
    let dir = tempfile::tempdir().unwrap();
    let env = Env {
        home: dir.path().to_path_buf(),
        claude_config_dir: None,
        codex_home: None,
        xdg_config_home: None,
        exe: PathBuf::from("/opt/acpmux"),
        args: vec!["acpmux-mcp".to_owned()],
        acpmux_home: None,
        claude_cli: None,
    };
    for app in App::ALL {
        let row = link(&env, app, false);
        assert_eq!(row.state, State::NotInstalled, "{app:?}");
        assert!(!row.config.exists());
    }
}

#[test]
fn a_config_that_is_not_json_is_named_and_left_as_it_is() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    let path = env.config_path(App::ClaudeDesktop);
    std::fs::write(&path, "{ not json").unwrap();
    let row = link(&env, App::ClaudeDesktop, false);
    assert_ne!(row.state, State::Linked);
    assert!(row.note.unwrap().contains("is not JSON"));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
}

/// A stand-in `claude` CLI that writes `~/.claude.json` the way `claude mcp add-json` and
/// `claude mcp remove` do, and logs its argv.
#[cfg(unix)]
fn fake_claude(dir: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let cli = dir.join("claude");
    let script = format!(
        r#"#!/usr/bin/env python3
import json, sys
log = open({log:?}, "a"); log.write(" ".join(sys.argv[1:]) + "\n")
path = {config:?}
try: doc = json.load(open(path))
except Exception: doc = {{}}
servers = doc.setdefault("mcpServers", {{}})
args = sys.argv[1:]
if args[:2] == ["mcp", "add-json"]:
    if args[4] in servers: sys.exit("MCP server cmux already exists in user config")
    servers[args[4]] = json.loads(args[5])
elif args[:2] == ["mcp", "remove"]:
    servers.pop(args[4], None)
json.dump(doc, open(path, "w"))
"#,
        log = dir.join("claude.log").to_string_lossy(),
        config = dir.join(".claude.json").to_string_lossy(),
    );
    std::fs::write(&cli, script).unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    cli
}

#[cfg(unix)]
#[test]
fn claude_code_is_linked_through_its_own_cli() {
    let dir = tempfile::tempdir().unwrap();
    let mut env = env(dir.path(), Some(fake_claude(dir.path())));
    assert_eq!(status(&env, App::ClaudeCode).state, State::NotLinked);
    let row = link(&env, App::ClaudeCode, false);
    assert_eq!(row.state, State::Linked, "{:?}", row.note);
    assert_eq!(status(&env, App::ClaudeCode).state, State::Linked);

    // A moved binary: the old entry is removed first, since add-json refuses a taken name.
    env.exe = PathBuf::from("/elsewhere/acpmux");
    assert_eq!(link(&env, App::ClaudeCode, false).state, State::Linked);
    assert_eq!(unlink(&env, App::ClaudeCode, false).state, State::NotLinked);
    let log = std::fs::read_to_string(dir.path().join("claude.log")).unwrap();
    let verbs: Vec<&str> = log.lines().map(|l| l.split(' ').nth(1).unwrap()).collect();
    assert_eq!(verbs, ["add-json", "remove", "add-json", "remove"]);
    assert!(log.lines().all(|l| l.contains("--scope user cmux")), "{log}");
}

#[test]
fn claude_code_without_its_cli_names_the_command_to_run() {
    let dir = tempfile::tempdir().unwrap();
    let env = env(dir.path(), None);
    std::fs::write(env.config_path(App::ClaudeCode), "{}").unwrap();
    let row = link(&env, App::ClaudeCode, false);
    assert_eq!(row.state, State::NotLinked);
    let note = row.note.unwrap();
    assert!(note.contains("claude mcp add-json --scope user cmux"), "{note}");
}
