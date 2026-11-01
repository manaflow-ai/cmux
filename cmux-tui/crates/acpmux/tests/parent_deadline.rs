//! `acpmux new --parent ... --timeout N` gives up at its deadline wherever the daemon stalls:
//! starting the child, tagging it or reading its reply (cmuxterm-hq#5120). Before, only the
//! server-side turn wait carried the limit, so a daemon that accepted and never answered held
//! the command forever.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent: the daemon is a fake socket.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-pd-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    dir
}

/// A daemon that answers the parent path's requests until `stall` and none from then on. It
/// reports the first request it leaves unanswered.
fn stalling_daemon(listener: UnixListener, stall: &'static str) -> mpsc::Receiver<String> {
    let (seen, unanswered) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let seen = seen.clone();
            std::thread::spawn(move || {
                let mut stalled = false;
                for line in BufReader::new(stream.try_clone().unwrap()).lines() {
                    let Ok(line) = line else { return };
                    let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
                    let Some(id) = msg.get("id") else { continue };
                    let method = msg["method"].as_str().unwrap_or_default();
                    let result = match method {
                        _ if stalled || method == stall => None,
                        "initialize" | "_acpmux/tag" => Some(json!({})),
                        "_acpmux/subsession/start" => {
                            Some(json!({"sessionId": "child", "name": "child"}))
                        }
                        "_acpmux/wait" => Some(json!({"sessions": [{"sessionId": "child",
                            "lastTurn": {"stopReason": "end_turn"}}]})),
                        _ => None,
                    };
                    let Some(result) = result else {
                        if !stalled {
                            stalled = true;
                            let _ = seen.send(method.to_owned());
                        }
                        continue;
                    };
                    let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
                    if writeln!(stream, "{reply}").is_err() {
                        return;
                    }
                }
            });
        }
    });
    unanswered
}

fn assert_bounded(stall: &'static str) {
    let dir = scratch(stall.rsplit('/').next().unwrap());
    let listener = UnixListener::bind(dir.join("acpmux.sock")).unwrap();
    let unanswered = stalling_daemon(listener, stall);
    let mut cmd = daemon_env::command(&dir, daemon_env::Agents::Deny, &[]);
    cmd.args(["new", "--parent", "chat", "--tag", "k=v", "--timeout", "1", "hello"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(dir.join("p"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let started = Instant::now();
    let mut child = cmd.spawn().unwrap();
    let Some(status) = child.wait_timeout(Duration::from_secs(10)).unwrap() else {
        let _ = child.kill();
        let _ = child.wait();
        panic!("{stall}: --parent outlived its --timeout");
    };
    let elapsed = started.elapsed();
    let out = child.wait_with_output().unwrap();
    let text = format!(
        "{stall}: status {status:?}\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(status.code(), Some(3), "{text}");
    assert_eq!(unanswered.try_recv().as_deref(), Ok(stall), "{text}");
    assert!(elapsed < Duration::from_secs(4), "{stall} escaped the deadline: {elapsed:?}");
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn a_parent_start_the_daemon_never_answers_ends_at_the_deadline() {
    assert_bounded("_acpmux/subsession/start");
}

#[test]
fn a_parent_tag_the_daemon_never_answers_ends_at_the_deadline() {
    assert_bounded("_acpmux/tag");
}

#[test]
fn a_parent_reply_read_the_daemon_never_answers_ends_at_the_deadline() {
    // The reply is read from the child's transcript.
    assert_bounded("_acpmux/attach");
}
