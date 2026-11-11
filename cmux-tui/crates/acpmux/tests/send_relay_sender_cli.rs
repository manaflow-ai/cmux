//! `acpmux send --relay NAME --relayed-from MACHINE/SESSION` from outside any session, against a
//! real daemon, as the lane-gh broker runs it (with or without `--from`): the receiving chat's
//! inbox holds another agent's message, its sender the relayed one, verified, with its harness,
//! however long the relayed name.
//! Leo, 2026-11-07: "Why does it say it's self-declared if we can just detect the thing?"
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::Duration;

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-rly-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The daemon refuses a state folder others may write to.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd.output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

/// The receiving chat's inbox thread whose sender record names `machine` as its relay's.
fn relayed_thread(dir: &Path, machine: &str) -> Option<Value> {
    let out = cli(dir, &["--json", "session", "inbox", "lane"]);
    let v: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    v["threads"].as_array()?.iter().find(|t| t["sender"]["relay"]["machine"] == machine).cloned()
}

#[test]
fn a_relayed_send_with_or_without_from_is_a_verified_agents_message_in_the_inbox() {
    let dir = scratch("s");
    let _shutdown = Shutdown(&dir);
    // A chat that ran a turn: another agent's message to it goes to its inbox.
    let made = cli(&dir, &["run", "-n", "lane", "warm up"]);
    assert!(made.status.success(), "the session: {}", text(&made));

    // A session name past `fromAgent`'s 64 characters (review of #37652, F1): the send still
    // goes, and its sender is still the relay's, whole.
    let long = format!("cloud-start-matrix-{}", "x".repeat(60));
    let cases =
        [("vm-1", "coord", None), ("vm-2", "coord", Some("vm-2/coord")), ("vm-3", &long, None)];
    for (machine, session, from) in cases {
        let relayed_from = format!("{machine}/{session}");
        let mut args = vec!["--json", "send", "--no-wait"];
        if let Some(from) = from {
            args.extend(["--from", from]);
        }
        args.extend([
            "--relay",
            "lane-gh",
            "--relayed-from",
            &relayed_from,
            "--relayed-harness",
            "codex",
            "lane",
            "status: green",
        ]);
        let sent = cli(&dir, &args);
        assert!(sent.status.success(), "{machine}: {}", text(&sent));
        let thread = (0..100).find_map(|_| {
            relayed_thread(&dir, machine).or_else(|| {
                std::thread::sleep(Duration::from_millis(100));
                None
            })
        });
        let thread = thread.unwrap_or_else(|| {
            panic!(
                "{machine}: no relayed thread: {}",
                text(&cli(&dir, &["--json", "session", "inbox", "lane"]))
            )
        });
        let sender = &thread["sender"];
        assert_eq!(
            (&sender["verification"], &sender["harness"], &sender["relay"]["session"]),
            (&json!("verified"), &json!("codex"), &json!(session)),
            "{machine}: {thread}"
        );
        assert_eq!(thread["from"], json!([relayed_from]), "{machine}: {thread}");
    }
}
