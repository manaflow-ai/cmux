//! `acpmux send --from NAME` from outside any session, against a real daemon with its inbox on:
//! a send that carries this host's sender token (`sender_token.rs`; `ACPMUX_SENDER_TOKEN` or
//! `--sender-token-file`, the daemon's `ACPMUX_HOME/sender-token`) puts a verified sender in the
//! receiving chat's inbox, verified by the host token. A wrong token leaves it declared.
//! Leo, 2026-11-11: "generally the "unverified sender" things should be more verified".
//! A send that presents none presents its daemon home's own: no sender has to remember to (Leo,
//! 2026-11-20: "sometimes you guys litearlly dont announce your permissions apparently which fucks
//! it up"). Each way a named send leaves a host is a case: `--from`, `ACPMUX_FROM` (what `reach`
//! sets across an ssh hop, and what fleet timers set), and a tool's `--notice`.
#![cfg(unix)]

use crate::daemon_env;

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
    cli_from(dir, args, token, None)
}

fn cli_from(dir: &Path, args: &[&str], token: Option<&str>, from_env: Option<&str>) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd.env_remove("ACPMUX_SENDER_TOKEN").env_remove("ACPMUX_FROM");
    if let Some(token) = token {
        cmd.env("ACPMUX_SENDER_TOKEN", token);
    }
    if let Some(name) = from_env {
        cmd.env("ACPMUX_FROM", name);
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

    // How a case names its sender: `--from`, `ACPMUX_FROM`, or a notice's `--sender`.
    #[derive(Clone, Copy)]
    enum Named {
        Flag,
        Env,
        Notice,
    }
    // One sender: its name, how it is named, its token by the environment, its token file,
    // and whether the host token verifies it.
    struct Case<'a> {
        name: &'a str,
        named: Named,
        env: Option<&'a str>,
        file: Option<&'a str>,
        verified: bool,
    }
    let case = |name, named, env, file, verified| Case { name, named, env, file, verified };
    let cases = [
        case("relay-env", Named::Flag, Some(token.as_str()), None, true),
        case("relay-file", Named::Flag, None, Some(path_arg.as_str()), true),
        case("relay-wrong", Named::Flag, None, Some(wrong_arg.as_str()), false),
        // Presents nothing: its daemon home's own token goes with it.
        case("relay-none", Named::Flag, None, None, true),
        case("reach-hop", Named::Env, None, None, true),
        case("land-notice", Named::Notice, None, None, true),
    ];
    for Case { name, named, env, file, verified } in cases {
        let mut args = vec!["--json", "send", "--no-wait"];
        match named {
            Named::Flag => args.extend(["--from", name]),
            Named::Env => {}
            Named::Notice => args.extend([
                "--notice",
                "--severity",
                "warn",
                "--sender",
                name,
                "--title",
                "merge stopped",
            ]),
        }
        if let Some(file) = file {
            args.extend(["--sender-token-file", file]);
        }
        args.extend(["lane", "status: green"]);
        let from_env = matches!(named, Named::Env).then_some(name);
        let sent = cli_from(&dir, &args, env, from_env);
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
    assert!(
        shown.contains("relay-env") && shown.contains("reach-hop"),
        "the inbox was read: {shown}"
    );
    assert!(!shown.contains(&token), "the token was shown: {shown}");
    assert!(!shown.contains("\"senderToken\""), "the token's key was shown: {shown}");
}
