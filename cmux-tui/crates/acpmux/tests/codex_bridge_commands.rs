//! Codex's slash commands and title through the in-process bridge, at the
//! CLI: a Codex session on a fixture `codex app-server`
//! (`fake_codex_stream.py`) gets the commands the codex-acp adapter gave it
//! (cmux-codex-acp tests/commands.rs compares them with that adapter in full;
//! this checks that they reach a person through acpmux). Regression of
//! 2026-10-20: when `codex` became the bridge, every command was gone and a
//! `/status` prompt went to the model as text.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The fixture app-server is this test's stand-in agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-cxc-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(args)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(dir.join("p"))
        .output()
        .unwrap()
}

/// The reply text of one `--json send`.
fn send(dir: &Path, prompt: &str) -> String {
    let out = cli(dir, &["--json", "send", "cx", prompt]);
    assert!(out.status.success(), "{prompt}: {}", String::from_utf8_lossy(&out.stderr));
    let last = cli(dir, &["last", "cx"]);
    String::from_utf8_lossy(&last.stdout).trim().to_owned()
}

/// Ends the daemon and its agents however the test ends.
struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

#[test]
fn codex_slash_commands_reach_the_person_through_the_bridge() {
    let dir = scratch();
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_codex_stream.py");
    let codex = dir.join("codex");
    fs::write(
        &codex,
        format!("#!/bin/sh\nexec python3 {} \"$@\"\n", daemon_env::sh_quote(fixture.display())),
    )
    .unwrap();
    fs::set_permissions(&codex, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let log = dir.join("fixture.log");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"codex-fixture": {"argv": [codex, "app-server"], "family": "codex",
            "env": {"FIX_LOG": log}}}})
        .to_string(),
    )
    .unwrap();
    let _shutdown = Shutdown(&dir);

    let first = cli(
        &dir,
        &["--json", "run", "-m", "codex-fixture", "-n", "cx", "--policy", "approve-all", "hello from the test"],
    );
    assert!(first.status.success(), "first turn: {}", String::from_utf8_lossy(&first.stderr));

    let skills = send(&dir, "/skills");
    assert_eq!(skills, "Available skills:\n- deploy: Deploy\n- triage: Triage a bug report");
    let mcp = send(&dir, "/mcp");
    assert_eq!(mcp, "Configured MCP servers:\n- docs: 2 tools, 1 resources, auth=unsupported");
    let status = send(&dir, "/status");
    assert!(status.starts_with("**Model:** gpt-6-astra[medium]"), "{status}");
    assert!(status.contains("**Account:** ChatGPT pro (dev@example.com)"), "{status}");
    let usage = send(&dir, "/review-branch");
    assert_eq!(usage, "Command \"/review-branch\" requires branch name.");
    let review = send(&dir, "/review-branch main");
    assert_eq!(review, "Review: no issues found.ok");
    let renamed = send(&dir, "/rename Release prep");
    assert!(renamed.is_empty() || !renamed.contains("/rename"), "{renamed}");

    let calls = fs::read_to_string(&log).unwrap_or_default();
    for call in [
        "skills/list",
        "mcpServerStatus/list",
        "account/rateLimits/read",
        r#"review/start {"delivery": "inline", "target": {"branch": "main", "type": "baseBranch"}}"#,
        r#"thread/name/set {"name": "Release prep"}"#,
        "title-turn model=gpt-5.6-luna schema=True",
    ] {
        assert!(calls.contains(call), "the app-server never got {call}:\n{calls}");
    }
    // No command went to the model as a prompt.
    assert!(!calls.contains("text=\"/"), "a command went to the model as text:\n{calls}");

    // The session's title: Codex's name for the thread after /rename.
    let ls = cli(&dir, &["--json", "ls"]);
    let sessions: Value = serde_json::from_slice(&ls.stdout).unwrap_or(Value::Null);
    let title = sessions
        .as_array()
        .or_else(|| sessions.get("sessions").and_then(Value::as_array))
        .and_then(|s| s.iter().find(|s| s["name"] == "cx"))
        .and_then(|s| s.get("title"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    assert_eq!(title, "Release prep", "acpmux ls: {sessions}");
}
