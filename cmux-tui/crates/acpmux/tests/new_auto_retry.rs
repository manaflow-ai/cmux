//! `acpmux new --machine auto` whose pick refuses the start goes on to the next machine.
//!
//! An automatic start on a machine whose own remote chain refuses it (its sandbox canary or
//! keeper: `remote.sandbox_refused`) started nothing there. The CLI places again with that
//! machine in `skip`, and the session is made on the next one, with that machine as its `peer`
//! and the folder the next machine gets. A refusal of the start's own inputs
//! (`remote.start_refused`) is refused on every machine, so the start ends at once. A daemon
//! that names the refused machine again, under another spelling of its name, ends it too.
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
    let dir = std::env::temp_dir().join(format!("amx-nar2-{tag}-{}", std::process::id()));
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

/// How the fixture daemon answers.
#[derive(Clone, Copy)]
struct Script {
    /// The `data.reason` of `first`'s refusal.
    reason: &'static str,
    /// The daemon reads `skip` (a current daemon), or ignores it and picks `First` again.
    reads_skip: bool,
}

/// What the fixture daemon saw: each `_acpmux/place` and each `session/new`, in order.
#[derive(Default)]
struct Seen {
    places: Vec<Value>,
    news: Vec<Value>,
}

/// A daemon on `dir`'s socket with two peers, `first` (the pick, whose remote chain refuses
/// the start) and `second` (which makes it).
fn fixture(dir: &Path, script: Script) -> (tokio::task::JoinHandle<()>, Arc<Mutex<Seen>>) {
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
                    let params = msg["params"].clone();
                    let reply = {
                        let mut seen = state.lock().unwrap();
                        match msg["method"].as_str().unwrap_or_default() {
                            "initialize" => Ok(json!({})),
                            "_acpmux/sessions" => Ok(json!({"sessions": [], "nextCursor": null})),
                            "_acpmux/place" => {
                                seen.places.push(params.clone());
                                let skip = params["skip"].as_array().cloned().unwrap_or_default();
                                let pick = if !script.reads_skip && !seen.news.is_empty() {
                                    "First"
                                } else if skip.iter().any(|s| s == "first") {
                                    "second"
                                } else {
                                    "first"
                                };
                                Ok(json!({"pick": pick, "local": false, "why": format!("{pick}: room for 3")}))
                            }
                            "session/new" => {
                                seen.news.push(params.clone());
                                let peer = params["_meta"]["acpmux"]["peer"].as_str().unwrap_or("");
                                if peer.eq_ignore_ascii_case("first") {
                                    Err(json!({"code": -32000,
                                        "message": "refused by first: remote chain refused: the sandbox canary shows no sandbox",
                                        "data": {"reason": script.reason, "host": "first"}}))
                                } else {
                                    let name = params["_meta"]["acpmux"]["name"].clone();
                                    Ok(json!({
                                        "sessionId": "00000001-0000-7000-8000-000000000000",
                                        "peer": peer,
                                        "name": name,
                                        "status": "idle",
                                        "cwd": params["cwd"],
                                        "turnCount": 0,
                                        "_meta": {"acpmux": {"name": name, "parent": null}},
                                    }))
                                }
                            }
                            _ => Ok(json!({})),
                        }
                    };
                    let response = match reply {
                        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                        Err(error) => json!({"jsonrpc": "2.0", "id": id, "error": error}),
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

/// Runs `acpmux --json new -d -m fake -n auto-x --machine auto` against the fixture; returns
/// the CLI's output and what the fixture saw.
async fn new_auto(tag: &str, script: Script) -> (Output, Vec<Value>, Vec<Value>) {
    let _ = HERMETIC;
    let dir = scratch(tag);
    let (server, seen) = fixture(&dir, script);
    let mut cmd = daemon_env::command(&dir, daemon_env::Agents::Deny, &[]);
    cmd.args(["--json", "new", "-d", "-m", "fake", "-n", "auto-x", "--machine", "auto"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(dir.join("p"));
    let out = tokio::time::timeout(
        std::time::Duration::from_secs(60),
        tokio::process::Command::from(cmd).output(),
    )
    .await
    .expect("the CLI did not finish within 60 s")
    .unwrap();
    server.abort();
    let _ = server.await;
    let seen = seen.lock().unwrap();
    let (places, news) = (seen.places.clone(), seen.news.clone());
    fs::remove_dir_all(&dir).unwrap();
    (out, places, news)
}

/// The pick's own remote chain refuses: the CLI places again with it in `skip`, and the session
/// is made on the next machine, with that machine as its peer and no folder from the first.
#[tokio::test]
async fn a_start_the_picks_chain_refuses_is_made_on_the_next_machine() {
    let script = Script { reason: "remote.sandbox_refused", reads_skip: true };
    let (out, places, news) = new_auto("next", script).await;
    assert!(out.status.success(), "{}\nplaces: {places:?}\nnews: {news:?}", text(&out));
    assert_eq!(places.len(), 2, "{places:?}");
    assert!(places[0].get("skip").is_none(), "the first pick skips nothing: {places:?}");
    assert_eq!(places[1]["skip"], json!(["first"]), "{places:?}");
    let peers: Vec<&Value> = news.iter().map(|p| &p["_meta"]["acpmux"]["peer"]).collect();
    assert_eq!(peers, [&json!("first"), &json!("second")], "{news:?}");
    // A peer's start with no --cwd sends no folder: the peer picks its own.
    assert!(news[1].get("cwd").is_none(), "{news:?}");
    let printed: Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("stdout is no JSON ({e}): {}", text(&out)));
    assert_eq!(printed["peer"], "second", "{}", text(&out));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("first refused the start (its remote chain)"), "{stderr}");
}

/// A refusal of the start's own inputs is refused on every machine: the start ends at once,
/// with no second pick and no second start.
#[tokio::test]
async fn a_start_refused_for_its_own_inputs_ends_at_once() {
    let script = Script { reason: "remote.start_refused", reads_skip: true };
    let (out, places, news) = new_auto("own", script).await;
    assert!(!out.status.success(), "{}", text(&out));
    assert_eq!((places.len(), news.len()), (1, 1), "places: {places:?}\nnews: {news:?}");
}

/// A daemon that ignores `skip` names the refused machine again, spelled `First`: the CLI
/// compares canonical names, ends the start, and never starts there a second time.
#[tokio::test]
async fn a_daemon_that_picks_the_refused_machine_again_ends_the_start() {
    let script = Script { reason: "remote.sandbox_refused", reads_skip: false };
    let (out, places, news) = new_auto("again", script).await;
    assert!(!out.status.success(), "{}", text(&out));
    assert_eq!((places.len(), news.len()), (2, 1), "places: {places:?}\nnews: {news:?}");
}
