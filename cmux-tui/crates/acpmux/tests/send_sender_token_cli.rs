//! `acpmux send --from NAME` from outside any session, against a real daemon with its inbox on:
//! a send that carries this host's sender token (`sender_token.rs`; `ACPMUX_SENDER_TOKEN` or
//! `--sender-token-file`, the daemon's `ACPMUX_HOME/sender-token`) puts a verified sender in the
//! receiving chat's inbox, verified by the host token. A wrong token, and none, leave it declared.
//! Leo, 2026-11-11: "generally the "unverified sender" things should be more verified".
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
    let dir = std::env::temp_dir().join(format!("amx-tok-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The daemon refuses a state folder others may write to.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all", "agentInbox": true})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str], token: Option<&str>) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd.env_remove("ACPMUX_SENDER_TOKEN");
    if let Some(token) = token {
        cmd.env("ACPMUX_SENDER_TOKEN", token);
    }
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
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"], None);
        let _ = fs::remove_dir_all(self.0);
    }
}

/// The receiving chat's inbox thread whose sender is `name`.
fn thread_from(dir: &Path, name: &str) -> Option<Value> {
    let out = cli(dir, &["--json", "session", "inbox", "lane"], None);
    let v: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    v["threads"]
        .as_array()?
        .iter()
        .find(|t| {
            t["sender"]["label"] == name
                || t["from"].as_array().is_some_and(|f| f.iter().any(|n| n == name))
        })
        .cloned()
}

#[test]
fn a_named_send_with_the_host_token_is_a_verified_sender_in_the_inbox() {
    let dir = scratch("s");
    let _shutdown = Shutdown(&dir);
    // A chat that ran a turn: another agent's message to it goes to its inbox. The daemon this
    // starts makes the host token.
    let made = cli(&dir, &["run", "-n", "lane", "warm up"], None);
    assert!(made.status.success(), "the session: {}", text(&made));
    let path = dir.join("sender-token");
    let token = fs::read_to_string(&path).expect("the daemon made the host token");
    let token = token.trim().to_owned();
    assert_eq!(token.len(), 64, "{token}");
    assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    let wrong = "0".repeat(64);
    let wrong_file = dir.join("wrong-token");
    fs::write(&wrong_file, &wrong).unwrap();
    let path_arg = path.to_string_lossy().into_owned();
    let wrong_arg = wrong_file.to_string_lossy().into_owned();

    // (sender, its token by the environment, its token file, verified by the host token)
    let cases: [(&str, Option<&str>, Option<&str>, bool); 4] = [
        ("relay-env", Some(&token), None, true),
        ("relay-file", None, Some(&path_arg), true),
        ("relay-wrong", None, Some(&wrong_arg), false),
        ("relay-none", None, None, false),
    ];
    for (name, env, file, verified) in cases {
        let mut args = vec!["--json", "send", "--no-wait", "--from", name];
        if let Some(file) = file {
            args.extend(["--sender-token-file", file]);
        }
        args.extend(["lane", "status: green"]);
        let sent = cli(&dir, &args, env);
        assert!(sent.status.success(), "{name}: {}", text(&sent));
        let thread = (0..100).find_map(|_| {
            thread_from(&dir, name).or_else(|| {
                std::thread::sleep(Duration::from_millis(100));
                None
            })
        });
        let thread = thread.unwrap_or_else(|| {
            panic!(
                "{name}: no thread: {}",
                text(&cli(&dir, &["--json", "session", "inbox", "lane"], None))
            )
        });
        let sender = &thread["sender"];
        if verified {
            assert_eq!(
                (&sender["verification"], &sender["verifiedBy"]),
                (&json!("verified"), &json!("host-token")),
                "{name}: {thread}"
            );
        } else {
            assert_eq!(sender["verification"], json!("declared"), "{name}: {thread}");
            assert!(sender.get("verifiedBy").is_none(), "{name}: {thread}");
        }
        // Verified by the token or not, a name is no proven session.
        assert_ne!(sender["authenticated"], json!(true), "{name}: {thread}");
    }
    // The token is in nothing the daemon keeps or shows for the chat.
    let inbox = cli(&dir, &["--json", "session", "inbox", "lane"], None);
    let shown = String::from_utf8_lossy(&inbox.stdout);
    assert!(shown.contains("relay-env"), "the inbox was read: {shown}");
    assert!(!shown.contains(&token), "the token was shown: {shown}");
    assert!(!shown.contains("\"senderToken\""), "the token's key was shown: {shown}");
}
