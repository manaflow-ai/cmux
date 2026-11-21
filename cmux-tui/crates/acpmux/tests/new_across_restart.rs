//! A named `new --reuse` (and `ensure`) whose daemon restarts during the create still ends with
//! one session of that name.
//!
//! A NEXT Cloud chat starts its agent with `acpmux --json new -d --reuse -n relay-<chat> ...`
//! (cmux-host's machine relay). The app's keyed acpmux start restarts the user's daemon, and a
//! `session/new` in flight then ends with no reply: "daemon connection closed while waiting for
//! the reply to session/new" (production, after 102.7 s; staging, twice in a row, the second
//! time a systemd daemon taking over one the CLI had started). The chat failed. The create may
//! have happened before the close, so the CLI must look the name up again, never create twice.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent: the daemon is the fixture below.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-nar-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The CLI refuses a state folder others may write to.
    fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    dir
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

/// What the fixture daemon saw: every `session/new` it got, and the sessions it made.
#[derive(Default)]
struct Seen {
    creates: usize,
    sessions: Vec<Value>,
    methods: Vec<String>,
}

/// A daemon on `dir`'s socket that closes the connection, without a reply, on the first `drops`
/// `session/new` requests, as a daemon restarted mid-create does. `made_before_drop` says which
/// of those (1-based) made the session before the close; one after the drops is answered.
fn fixture(
    dir: &Path,
    drops: usize,
    made_before_drop: &'static [usize],
) -> (tokio::task::JoinHandle<()>, Arc<Mutex<Seen>>) {
    let listener = tokio::net::UnixListener::bind(dir.join("acpmux.sock")).unwrap();
    let seen = Arc::new(Mutex::new(Seen::default()));
    let state = seen.clone();
    let server = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let state = state.clone();
            connections.spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = tokio::io::BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let msg: Value = serde_json::from_str(&line).unwrap();
                    let Some(id) = msg.get("id") else { continue };
                    let method = msg["method"].as_str().unwrap_or_default().to_owned();
                    let reply = {
                        let mut seen = state.lock().unwrap();
                        seen.methods.push(method.clone());
                        match method.as_str() {
                            "initialize" => Ok(json!({})),
                            "_acpmux/sessions" => {
                                Ok(json!({"sessions": seen.sessions, "nextCursor": null}))
                            }
                            "_acpmux/info" => {
                                let key = msg["params"]["sessionId"].as_str().unwrap_or_default();
                                match seen.sessions.iter().find(|s| {
                                    s["name"].as_str() == Some(key)
                                        || s["sessionId"].as_str() == Some(key)
                                }) {
                                    Some(s) => Ok(s.clone()),
                                    None => Err(format!("no session named {key}")),
                                }
                            }
                            "session/new" => {
                                seen.creates += 1;
                                let n = seen.creates;
                                let name = msg["params"]["_meta"]["acpmux"]["name"]
                                    .as_str()
                                    .unwrap_or_default()
                                    .to_owned();
                                let session = json!({
                                    "sessionId": format!("0000000{n}-0000-7000-8000-000000000000"),
                                    "name": name,
                                    "status": "idle",
                                    "cwd": msg["params"]["cwd"],
                                    "turnCount": 0,
                                    "_meta": {"acpmux": {"name": name, "parent": null}},
                                });
                                if n > drops || made_before_drop.contains(&n) {
                                    seen.sessions.push(session.clone());
                                }
                                if n <= drops {
                                    // The daemon stops: this connection ends with no reply.
                                    return;
                                }
                                Ok(session)
                            }
                            _ => Ok(json!({})),
                        }
                    };
                    let response = match reply {
                        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                        Err(message) => json!({"jsonrpc": "2.0", "id": id,
                            "error": {"code": -32602, "message": message}}),
                    };
                    if write.write_all(format!("{response}\n").as_bytes()).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    (server, seen)
}

async fn run_cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::Deny, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    tokio::time::timeout(
        std::time::Duration::from_secs(60),
        tokio::process::Command::from(cmd).output(),
    )
    .await
    .expect("the CLI did not finish within 60 s")
    .unwrap()
}

/// The relay's launch, with the daemon closing the connection during `session/new`.
/// `creates`: the `session/new` requests the fixture should see. A retry after a create that
/// happened finds that session and sends no other.
async fn relay_new(tag: &str, drops: usize, made_before_drop: &'static [usize], creates: usize) {
    let _ = HERMETIC;
    let dir = scratch(tag);
    let (server, seen) = fixture(&dir, drops, made_before_drop);
    let cwd = dir.join("p");
    let cwd = cwd.to_str().unwrap();
    let out = run_cli(
        &dir,
        &[
            "--json",
            "new",
            "-d",
            "--reuse",
            "-m",
            "fake",
            "-n",
            "relay-x",
            "--machine",
            "local",
            "--cwd",
            cwd,
        ],
    )
    .await;
    server.abort();
    let _ = server.await;
    let seen = seen.lock().unwrap();
    fs::remove_dir_all(&dir).unwrap();
    assert!(
        out.status.success(),
        "the launch failed instead of reconnecting: {}\nrequests: {:?}",
        text(&out),
        seen.methods
    );
    let named: Vec<&Value> = seen.sessions.iter().filter(|s| s["name"] == "relay-x").collect();
    assert_eq!(named.len(), 1, "sessions named relay-x: {:?}", seen.sessions);
    assert_eq!(seen.creates, creates, "session/new requests: {:?}", seen.methods);
    let printed: Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("stdout is no JSON ({e}): {}", text(&out)));
    assert_eq!(printed["sessionId"], named[0]["sessionId"], "{}", text(&out));
    assert_eq!(printed["name"], "relay-x", "{}", text(&out));
}

/// The create happened before the close: the retry finds it and makes no second one.
#[tokio::test]
async fn a_reuse_launch_whose_daemon_restarts_mid_create_finds_the_session_it_made() {
    relay_new("made", 1, &[1], 1).await;
}

/// The close came before the create: the retry makes the session.
#[tokio::test]
async fn a_reuse_launch_whose_daemon_restarts_before_the_create_makes_it_on_the_next() {
    relay_new("lost", 1, &[], 2).await;
}

/// Two handovers in a row (staging: the second came 3 s after the first), the second after its
/// create: still one session.
#[tokio::test]
async fn a_reuse_launch_survives_two_handovers_in_a_row() {
    relay_new("twice", 2, &[2], 2).await;
}

/// Without `--reuse` nothing can find the session a lost create made, so the launch does not
/// retry: it fails with the daemon's close, and makes at most the one session.
#[tokio::test]
async fn a_launch_without_reuse_does_not_retry_its_create() {
    let _ = HERMETIC;
    let dir = scratch("noreuse");
    let (server, seen) = fixture(&dir, 1, &[1]);
    let out =
        run_cli(&dir, &["--json", "new", "-d", "-m", "fake", "-n", "plain", "--machine", "local"])
            .await;
    server.abort();
    let _ = server.await;
    let seen = seen.lock().unwrap();
    fs::remove_dir_all(&dir).unwrap();
    assert!(!out.status.success(), "{}", text(&out));
    assert_eq!(seen.creates, 1, "session/new requests: {:?}", seen.methods);
    assert!(text(&out).contains("daemon connection closed"), "{}", text(&out));
}

/// `ensure NAME`, the same find-or-create: a restart after its create finds that session.
#[tokio::test]
async fn ensure_whose_daemon_restarts_mid_create_finds_the_session_it_made() {
    let _ = HERMETIC;
    let dir = scratch("ensure");
    let (server, seen) = fixture(&dir, 1, &[1]);
    let cwd = dir.join("p");
    let out =
        run_cli(&dir, &["--json", "ensure", "lane", "-m", "fake", "--cwd", cwd.to_str().unwrap()])
            .await;
    server.abort();
    let _ = server.await;
    let seen = seen.lock().unwrap();
    fs::remove_dir_all(&dir).unwrap();
    assert!(out.status.success(), "{}\nrequests: {:?}", text(&out), seen.methods);
    assert_eq!(seen.creates, 1, "session/new requests: {:?}", seen.methods);
    assert_eq!(seen.sessions.len(), 1, "{:?}", seen.sessions);
    let printed: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(printed["name"], "lane", "{}", text(&out));
}
