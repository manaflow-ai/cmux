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

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-cxc{tag}-{}", std::process::id()));
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

/// A home whose `codex-fixture` harness runs the fixture app-server; `extra`
/// goes into config.json beside it. Returns the fixture's log path.
fn home(dir: &Path, extra: Value) -> PathBuf {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_codex_stream.py");
    let codex = dir.join("codex");
    fs::write(
        &codex,
        format!("#!/bin/sh\nexec python3 {} \"$@\"\n", daemon_env::sh_quote(fixture.display())),
    )
    .unwrap();
    fs::set_permissions(&codex, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let log = dir.join("fixture.log");
    let mut config = json!({"harnesses": {"codex-fixture": {"argv": [codex, "app-server"], "family": "codex",
        "env": {"FIX_LOG": log}}}});
    if let (Some(c), Value::Object(extra)) = (config.as_object_mut(), extra) {
        c.extend(extra);
    }
    fs::write(dir.join("config.json"), config.to_string()).unwrap();
    log
}

/// The fixture log after an unnamed Codex chat's first turn and one more
/// prompt (by then a title call after the first turn is in the log).
fn unnamed_chat_calls(tag: &str, extra: Value) -> String {
    let dir = scratch(tag);
    let log = home(&dir, extra);
    let _shutdown = Shutdown(&dir);
    let first = cli(
        &dir,
        &["--json", "run", "-m", "codex-fixture", "--policy", "approve-all", "hello from the test"],
    );
    assert!(first.status.success(), "first turn: {}", String::from_utf8_lossy(&first.stderr));
    let out: Value = serde_json::from_slice(&first.stdout).unwrap_or(Value::Null);
    let name = out["name"].as_str().unwrap_or_else(|| panic!("no name: {out}")).to_owned();
    let next = cli(&dir, &["--json", "send", &name, "/mcp"]);
    assert!(next.status.success(), "/mcp: {}", String::from_utf8_lossy(&next.stderr));
    fs::read_to_string(&log).unwrap_or_default()
}

/// An unnamed chat gets the bridge's generated title, as the codex-acp
/// adapter gave it; `titles.generate: false` stops that model call
/// (Lawrence 2026-10-21) and the chat keeps its first prompt as its title.
#[test]
fn titles_generate_decides_the_codex_title_call() {
    let on = unnamed_chat_calls("on", json!({}));
    assert!(on.contains("title-turn model=gpt-5.6-luna schema=True"), "no title call:\n{on}");
    let off = unnamed_chat_calls("off", json!({"titles": {"generate": false}}));
    assert!(!off.contains("title-turn"), "the title model was asked:\n{off}");
    assert!(!off.contains("\"name\": \"Greeting"), "a generated title was set:\n{off}");
}

#[test]
fn codex_slash_commands_reach_the_person_through_the_bridge() {
    let dir = scratch("");
    let log = home(&dir, json!({}));
    let _shutdown = Shutdown(&dir);

    let first = cli(
        &dir,
        &[
            "--json",
            "run",
            "-m",
            "codex-fixture",
            "-n",
            "cx",
            "--policy",
            "approve-all",
            "hello from the test",
        ],
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
    send(&dir, "/rename Release prep");
    // The bridge answers /rename with Codex's reply; Codex's thread/name/updated
    // comes right after it on the same stream, so one more prompt's reply comes
    // after the title reached the hub (no wait on a clock).
    send(&dir, "/mcp");

    let calls = fs::read_to_string(&log).unwrap_or_default();
    for call in [
        "skills/list",
        "mcpServerStatus/list",
        "account/rateLimits/read",
        r#"review/start {"delivery": "inline", "target": {"branch": "main", "type": "baseBranch"}}"#,
        r#"thread/name/set {"name": "Release prep"}"#,
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

    // A chat the person named (`-n cx`) never gets a generated title, also
    // after its harness titled it and the daemon started it again (session/load).
    let stop = cli(&dir, &["daemon", "shutdown", "--end-agents"]);
    assert!(stop.status.success(), "shutdown: {}", String::from_utf8_lossy(&stop.stderr));
    // (The fixture keeps no thread name across processes: the title is checked above.)
    send(&dir, "hello again after a restart");
    send(&dir, "/mcp");
    let calls = fs::read_to_string(&log).unwrap_or_default();
    assert!(calls.contains("thread/resume"), "no reload:\n{calls}");
    assert!(!calls.contains("title-turn"), "a named chat's title was generated:\n{calls}");
}
