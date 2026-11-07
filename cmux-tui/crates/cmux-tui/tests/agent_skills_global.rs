//! cmux skills reach terminal agents only when the person installs them (Aziz 2026-11-06:
//! "terminals don't need to have the skills by default ... a way of installing them globally").
//!
//! A plain `claude` in a cmux terminal starts with cmux's hooks and no cmux skill or plugin, and
//! nothing is written to the person's skill folders. `cmux agent skills install` puts the skills
//! in Claude Code's and the shared Agent Skills folders, leaves a folder the person made alone,
//! and `uninstall` removes only what it wrote.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::process::Command;

use serde_json::Value;

fn cli(home: &Path, args: &[&str]) -> (bool, Value) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--json")
        .args(args)
        .env("HOME", home)
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .output()
        .unwrap();
    let text = if output.status.success() { &output.stdout } else { &output.stderr };
    let value = serde_json::from_slice(text)
        .unwrap_or_else(|e| panic!("{e}: {}", String::from_utf8_lossy(text)));
    (output.status.success(), value)
}

fn row<'a>(value: &'a Value, id: &str) -> &'a Value {
    let body = value.get("details").unwrap_or(value);
    body["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["provider"] == id)
        .unwrap_or_else(|| panic!("no {id} row in {value}"))
}

#[test]
fn a_terminal_claude_gets_no_cmux_skills_by_default() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let bin = root.path().join("bin");
    for dir in [&home, &bin] {
        fs::create_dir_all(dir).unwrap();
    }
    let received = root.path().join("claude-args");
    let claude = bin.join("claude");
    fs::write(&claude, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", received.display()))
        .unwrap();
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
    let socket = root.path().join("mux.sock");
    let _listener = UnixListener::bind(&socket).unwrap();

    let status = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["agent", "claude-wrapper", "hello"])
        .current_dir(&home)
        .env("HOME", &home)
        .env("PATH", &bin)
        .env("CMUX_TUI_SOCKET", &socket)
        .env("CMUX_TUI_TERMINAL_ID", "term_1")
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("CMUX_TUI_HOOK")
        .env_remove("CMUX_TUI_CLAUDE_WRAPPER_ACTIVE")
        .env_remove("CMUX_TUI_CLAUDE_HOOKS_DISABLED")
        .status()
        .unwrap();
    assert!(status.success());
    let args = fs::read_to_string(&received).unwrap();
    assert!(args.lines().any(|a| a == "--settings"), "hooks were not injected: {args}");
    assert!(!args.lines().any(|a| a.starts_with("--plugin")), "a terminal got a plugin: {args}");
    for folder in [".claude/skills", ".agents/skills"] {
        assert!(!home.join(folder).exists(), "{folder} was written without an install");
    }
    let (ok, status) = cli(&home, &["agent", "skills", "status"]);
    assert!(ok, "{status}");
    assert_eq!(row(&status, "claude")["state"], "absent", "{status}");
    assert_eq!(row(&status, "agents")["state"], "absent", "{status}");
}

#[test]
fn skills_install_globally_and_uninstall_leaves_the_persons_own() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path();
    // The person's own skill at a cmux name: never replaced, never removed.
    let own = home.join(".claude/skills/cmux-browser");
    fs::create_dir_all(&own).unwrap();
    fs::write(own.join("SKILL.md"), "---\nname: cmux-browser\ndescription: mine\n---\n").unwrap();

    let (ok, installed) = cli(home, &["agent", "skills", "install", "--global"]);
    assert!(!ok, "a conflict must fail the install: {installed}");
    let claude = row(&installed, "claude");
    assert_eq!(claude["state"], "conflict", "{installed}");
    assert_eq!(claude["reason"], "not_owned", "{installed}");
    assert_eq!(row(&installed, "agents")["state"], "installed", "{installed}");
    assert_eq!(
        fs::read_to_string(own.join("SKILL.md")).unwrap(),
        "---\nname: cmux-browser\ndescription: mine\n---\n"
    );
    for skill in ["cmux", "cmux-customization", "acpmux"] {
        let dir = home.join(".claude/skills").join(skill);
        assert!(dir.join("SKILL.md").is_file(), "{skill} missing for Claude Code");
        assert!(dir.join(".cmux-skill.json").is_file(), "{skill} has no ownership marker");
    }
    for skill in ["cmux", "cmux-browser", "cmux-customization", "acpmux"] {
        let file = home.join(".agents/skills").join(skill).join("SKILL.md");
        let text = fs::read_to_string(&file).unwrap();
        assert!(text.contains(&format!("name: {skill}")), "{file:?}: {text}");
    }
    assert!(home.join(".agents/skills/cmux/references/panes-surfaces.md").is_file());

    // Once the person's folder moves, the install completes and status says so.
    fs::remove_dir_all(&own).unwrap();
    let (ok, again) = cli(home, &["agent", "skills", "install", "claude"]);
    assert!(ok, "{again}");
    assert_eq!(row(&again, "claude")["state"], "installed", "{again}");
    let (_, status) = cli(home, &["agent", "skills", "status"]);
    assert_eq!(row(&status, "claude")["state"], "installed", "{status}");
    assert_eq!(row(&status, "agents")["state"], "installed", "{status}");

    // A person's own skill beside cmux's survives uninstall.
    let mine = home.join(".agents/skills/deploy");
    fs::create_dir_all(&mine).unwrap();
    fs::write(mine.join("SKILL.md"), "---\nname: deploy\ndescription: d\n---\n").unwrap();
    let (ok, removed) = cli(home, &["agent", "skills", "uninstall"]);
    assert!(ok, "{removed}");
    assert_eq!(row(&removed, "claude")["state"], "absent", "{removed}");
    assert_eq!(row(&removed, "agents")["state"], "absent", "{removed}");
    assert!(mine.join("SKILL.md").is_file(), "uninstall removed the person's own skill");
    assert!(!home.join(".agents/skills/cmux").exists());
}
