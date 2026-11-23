use std::collections::HashMap;
use std::fs;

use super::*;

fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
    let map: HashMap<String, OsString> =
        pairs.iter().map(|(key, value)| ((*key).to_owned(), OsString::from(value))).collect();
    move |name| map.get(name).cloned()
}

#[test]
fn any_launcher_plugin_copy_constants_match_the_command_writer() {
    assert_eq!(ORIGIN_ENV, cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN_ENV);
    assert_eq!(PLUGIN_ORIGIN, cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN);
}

#[test]
fn any_launcher_nested_claude_plugin_copy_stands_down_under_the_terminal_claim() {
    let plugin = (ORIGIN_ENV, PLUGIN_ORIGIN);
    let here = (TERMINAL_ENV, "term_a");
    let claimed = (OWNER_ENV, "term_a/outer-1");
    let run = |session: &str, pairs: &[(&str, &str)]| {
        stands_down("claude", "UserPromptSubmit", Some(session), env(pairs))
    };
    // A Claude that the terminal's Claude started: another session.
    assert!(run("nested-2", &[plugin, here, claimed]));
    // The claiming Claude itself, and a terminal nobody claimed.
    assert!(!run("outer-1", &[plugin, here, claimed]));
    assert!(!run("nested-2", &[plugin, here]));
    // A claim for another terminal: this Claude runs in its own terminal
    // (`cmux agent start` from a tool command).
    assert!(!run("nested-2", &[plugin, (TERMINAL_ENV, "term_b"), claimed]));
    // Every copy reads claims: the installed and the shim's hooks too.
    assert!(run("nested-2", &[here, claimed]));
    assert!(!run("outer-1", &[here, claimed]));
    assert!(!stands_down("codex", "Stop", Some("nested-2"), env(&[here, claimed])));
    // A malformed claim is none.
    assert!(!run("nested-2", &[plugin, here, (OWNER_ENV, "term_a")]));
}

#[test]
fn any_launcher_plugin_session_start_claims_the_terminal_in_the_env_file() {
    let dir = tempfile::tempdir().unwrap();
    // Claude Code names the file but does not create it.
    let file = dir.path().join("env.sh");
    let path = file.to_str().unwrap();
    let plugin = (ORIGIN_ENV, PLUGIN_ORIGIN);
    let here = (TERMINAL_ENV, "term_a");
    let envfile = (CLAUDE_ENV_FILE, path);
    claim_terminal("claude", "SessionStart", Some("outer-1"), env(&[plugin, here, envfile]));
    assert_eq!(
        fs::read_to_string(&file).unwrap_or_default(),
        format!("export {OWNER_ENV}=term_a/outer-1\n")
    );
    // The installed or shim copy of SessionStart claims too.
    let installed_file = dir.path().join("installed.sh");
    let installed_path = installed_file.to_str().unwrap();
    claim_terminal(
        "claude",
        "SessionStart",
        Some("outer-1"),
        env(&[here, (CLAUDE_ENV_FILE, installed_path)]),
    );
    assert_eq!(
        fs::read_to_string(&installed_file).unwrap_or_default(),
        format!("export {OWNER_ENV}=term_a/outer-1\n")
    );
    fs::write(&file, "export KEEP=1\n").unwrap();
    claim_terminal("claude", "SessionStart", Some("outer-1"), env(&[plugin, here, envfile]));
    // Not a SessionStart, not Claude, an id a shell would read as code, or
    // no session: nothing is written.
    claim_terminal("claude", "Stop", Some("outer-1"), env(&[plugin, here, envfile]));
    claim_terminal("codex", "SessionStart", Some("outer-1"), env(&[plugin, here, envfile]));
    claim_terminal("claude", "SessionStart", Some("x;rm -rf ~"), env(&[plugin, here, envfile]));
    claim_terminal("claude", "SessionStart", None, env(&[plugin, here, envfile]));
    claim_terminal(
        "claude",
        "SessionStart",
        Some("outer-1"),
        env(&[plugin, (TERMINAL_ENV, "term_a$(x)"), envfile]),
    );
    assert_eq!(
        fs::read_to_string(&file).unwrap(),
        format!("export KEEP=1\nexport {OWNER_ENV}=term_a/outer-1\n")
    );
    // The claim it exports makes a Claude that a tool command starts
    // stand down (tests/claude_any_launcher.rs sources the file in a shell).
    let written = fs::read_to_string(&file).unwrap();
    let claim = written
        .lines()
        .find_map(|line| line.strip_prefix(&format!("export {OWNER_ENV}=")))
        .unwrap();
    assert!(stands_down(
        "claude",
        "SessionStart",
        Some("nested-2"),
        env(&[plugin, here, (OWNER_ENV, claim)])
    ));
}

#[test]
fn any_launcher_plugin_copy_stands_down_only_beside_an_installed_copy() {
    let dir = tempfile::tempdir().unwrap();
    let installed = dir.path().join("installed");
    let other = dir.path().join("other");
    let home = dir.path().join("home");
    for folder in [installed.clone(), other.clone(), home.join(".claude")] {
        fs::create_dir_all(folder).unwrap();
    }
    let installed_command = r#"h=${CMUX_TUI_HOOK:-x};"${h:-:}" 'claude' 'Stop' 2>/dev/null||:;echo {};#cmux-tui-journal-hook"#;
    let settings = |command: &str| {
        serde_json::json!({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": command}]}]}})
            .to_string()
    };
    fs::write(installed.join("settings.json"), settings(installed_command)).unwrap();
    // A user hook of its own, and a copied plugin command, are not installs.
    fs::write(other.join("settings.json"), settings("echo mine; echo {}")).unwrap();
    fs::write(
        home.join(".claude/settings.json"),
        settings(&format!("export {ORIGIN_ENV}={PLUGIN_ORIGIN};{installed_command}")),
    )
    .unwrap();
    let (installed, other, home) =
        (installed.to_str().unwrap(), other.to_str().unwrap(), home.to_str().unwrap());
    let plugin = (ORIGIN_ENV, PLUGIN_ORIGIN);
    let hook = ("CMUX_TUI_HOOK", "/opt/cmux-tui-hook");
    // The installed copy runs: the plugin copy stands down, for that event only.
    assert!(stands_down(
        "claude",
        "Stop",
        None,
        env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
    ));
    assert!(!stands_down(
        "claude",
        "SessionStart",
        None,
        env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
    ));
    // The installed command finds no helper: it is a no-op, the plugin reports.
    assert!(!stands_down("claude", "Stop", None, env(&[plugin, ("CLAUDE_CONFIG_DIR", installed)])));
    // Another config directory without the install, or the default one.
    assert!(!stands_down(
        "claude",
        "Stop",
        None,
        env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", other)])
    ));
    assert!(!stands_down("claude", "Stop", None, env(&[plugin, hook, ("HOME", home)])));
    // Not the plugin copy: the installed run itself always reports.
    assert!(!stands_down("claude", "Stop", None, env(&[hook, ("CLAUDE_CONFIG_DIR", installed)])));
    assert!(!stands_down(
        "codex",
        "Stop",
        None,
        env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
    ));
    // Hooks turned off: the plugin copy does nothing.
    assert!(stands_down(
        "claude",
        "Stop",
        None,
        env(&[plugin, (HOOKS_DISABLED_ENV, "1"), ("CLAUDE_CONFIG_DIR", other)])
    ));
}
