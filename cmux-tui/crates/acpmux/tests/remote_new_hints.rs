//! A `session/new` for a peer that the peer refuses says why (`data.reason`) and what
//! works instead (`data.try`, a command to copy), and that command works (Leo,
//! 2026-10-24: "we improve the instructions and the error messages and the hints ... or we
//! just ... do things more automatically"). The trust rules stay as they are: a remote or
//! Web caller still starts sessions only in the policies and modes it could before.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A folder of this test's own under the temp dir, made fresh.
fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("remote-new-hints-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(&dir).unwrap()
}

/// A hub whose only remote folder root is `root`.
fn hub(root: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "webRoots": [root],
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    fn open(hub: &Arc<Hub>, origin: Origin) -> C {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        C { tx, rx, next: 0 }
    }

    /// The whole response: `result` or `error`.
    async fn call(&mut self, m: &str, p: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

fn new(meta: Value, cwd: Option<&Path>) -> Value {
    let mut p = json!({"mcpServers": [], "_meta": {"acpmux": meta}});
    if let Some(cwd) = cwd {
        p["cwd"] = json!(cwd);
    }
    p
}

fn reason(r: &Value) -> &str {
    r["error"]["data"]["reason"].as_str().unwrap_or_else(|| panic!("no reason: {r}"))
}

fn cwd_of(hub: &Arc<Hub>, r: &Value) -> PathBuf {
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("session/new failed: {r}"));
    hub.resolve(id).unwrap().meta().cwd.clone()
}

// The owning daemon's side: each refusal names its reason.

#[tokio::test]
async fn each_remote_new_refusal_names_its_reason_and_a_peer_hears_the_allowed_roots() {
    let root = scratch("reasons");
    let outside = scratch("reasons-outside");
    let hub = hub(&root);

    let mut web = C::open(&hub, Origin::Web);
    let r = web.call(method::SESSION_NEW, new(json!({"policy": "approve-all"}), Some(&root))).await;
    assert_eq!(reason(&r), "remote.policy_refused", "{r}");
    assert_eq!(r["error"]["data"]["servedAs"], "remote", "{r}");
    // The folder is judged first, so one refusal names every field to change.
    let both = new(json!({"policy": "approve-all"}), Some(&root.join("missing")));
    let r = web.call(method::SESSION_NEW, both).await;
    assert_eq!(reason(&r), "remote.cwd_missing", "{r}");
    let r = web.call(method::SESSION_NEW, new(json!({"mode": "yolo"}), Some(&root))).await;
    assert_eq!(reason(&r), "remote.mode_refused", "{r}");
    let r = web.call(method::SESSION_NEW, new(json!({}), Some(&root.join("missing")))).await;
    assert_eq!(reason(&r), "remote.cwd_missing", "{r}");
    assert_eq!(r["error"]["data"]["cause"], "missing", "{r}");
    assert!(!root.join("missing").exists(), "a Web connection never makes a folder");
    // A file is no folder, and no `mkdir -p` makes one there.
    std::fs::write(root.join("file"), "x").unwrap();
    let r = web.call(method::SESSION_NEW, new(json!({}), Some(&root.join("file")))).await;
    assert_eq!(r["error"]["data"]["cause"], "unusable", "{r}");
    let r = web.call(method::SESSION_NEW, new(json!({}), Some(&outside))).await;
    assert_eq!(reason(&r), "remote.cwd_outside_roots", "{r}");
    // The Web is not told which folders this machine has.
    assert!(r["error"]["data"].get("roots").is_none(), "{r}");

    // The owner's own daemon is told the roots it may use, in the message too.
    let mut peer = C::open(&hub, Origin::Peer);
    let r = peer.call(method::SESSION_NEW, new(json!({}), Some(&outside))).await;
    assert_eq!(reason(&r), "remote.cwd_outside_roots", "{r}");
    assert_eq!(r["error"]["data"]["servedAs"], "peer", "{r}");
    assert_eq!(r["error"]["data"]["roots"][0], json!(root), "{r}");
    // And a folder there to use instead: ROOT/<leaf>, or ROOT when that is a link.
    assert_eq!(r["error"]["data"]["tryCwd"], json!(root.join(outside.file_name().unwrap())));
    std::os::unix::fs::symlink(&outside, root.join(outside.file_name().unwrap())).unwrap();
    let r = peer.call(method::SESSION_NEW, new(json!({}), Some(&outside))).await;
    assert_eq!(r["error"]["data"]["tryCwd"], json!(root), "{r}");
    let message = r["error"]["message"].as_str().unwrap();
    assert!(message.contains(&root.to_string_lossy().into_owned()), "{message}");
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&outside);
}

#[tokio::test]
async fn a_peers_missing_folder_inside_a_root_is_made_and_one_outside_is_refused() {
    let root = scratch("mkdir");
    let outside = scratch("mkdir-outside");
    let hub = hub(&root);
    let mut peer = C::open(&hub, Origin::Peer);

    let want = root.join("lane").join("x");
    let r = peer.call(method::SESSION_NEW, new(json!({"name": "made"}), Some(&want))).await;
    assert_eq!(cwd_of(&hub, &r), want, "{r}");
    assert!(want.is_dir());

    // A `..` that leaves the root is not made.
    let escape = root.join("..").join(outside.file_name().unwrap()).join("y");
    let r = peer.call(method::SESSION_NEW, new(json!({}), Some(&escape))).await;
    assert_eq!(reason(&r), "remote.cwd_outside_roots", "{r}");
    let r = peer.call(method::SESSION_NEW, new(json!({}), Some(&outside.join("z")))).await;
    assert_eq!(reason(&r), "remote.cwd_outside_roots", "{r}");
    assert!(!outside.join("y").exists() && !outside.join("z").exists());

    // A link inside the root, dangling or not, is never followed to make a folder.
    let gone = outside.join("gone");
    std::os::unix::fs::symlink(&gone, root.join("dangling")).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("out")).unwrap();
    for asked in [root.join("dangling").join("child"), root.join("out").join("child")] {
        let r = peer.call(method::SESSION_NEW, new(json!({}), Some(&asked))).await;
        assert!(r["error"].is_object(), "{asked:?}: {r}");
    }
    assert!(!gone.exists() && !outside.join("child").exists());

    // Nothing is made for a start refused anyway (a mode at a remote start).
    let later = root.join("later");
    let r = peer.call(method::SESSION_NEW, new(json!({"mode": "yolo"}), Some(&later))).await;
    assert_eq!(reason(&r), "remote.mode_refused", "{r}");
    assert!(!later.exists());
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&outside);
}

#[tokio::test]
async fn creation_tags_are_recorded_before_new_returns() {
    let root = scratch("tags");
    let hub = hub(&root);
    let mut peer = C::open(&hub, Origin::Peer);
    let r = peer
        .call(
            method::SESSION_NEW,
            new(json!({"name": "tagged", "tags": {"a": "b", "owner": "leo"}}), Some(&root)),
        )
        .await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}"));
    assert_eq!(hub.resolve(id).unwrap().meta().tags["a"].value, "b");
    assert_eq!(hub.resolve(id).unwrap().meta().tags["owner"].value, "leo");
    let _ = std::fs::remove_dir_all(&root);
}

// The forwarding daemon's side: the refusal carries the command that works.

/// B's WebSocket listener, with a peer token when `peer` (A is then served as a peer,
/// else as a remote Web client). Returns the port and the token for A.
async fn listen(b: Arc<Hub>, tag: &str, peer: bool) -> (u16, Option<String>) {
    let home = scratch(&format!("home-{tag}"));
    let auth = peer.then(|| Arc::new(PeerAuth::create(&home).unwrap()));
    let token = peer
        .then(|| std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap());
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(b, l, "tok".into(), WsAuth { local_app: None, peer: auth }));
    (port, token)
}

/// A, with B as its peer `b`; and B.
async fn pair(tag: &str, as_peer: bool, root: &Path) -> (Arc<Hub>, Arc<Hub>) {
    let b = hub(root);
    let (port, token) = listen(b.clone(), tag, as_peer).await;
    let a = hub(root);
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), token, true)
        .await
        .unwrap();
    (a, b)
}

fn tried(r: &Value) -> String {
    r["error"]["data"]["try"].as_str().unwrap_or_else(|| panic!("no try: {r}")).to_owned()
}

#[tokio::test]
async fn retry_metadata_stays_local_when_new_is_forwarded() {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;

    let root = scratch("retry-metadata");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (received_tx, mut received_rx) = mpsc::channel(1);
    let server = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        while let Some(Ok(Ws::Text(text))) = ws.next().await {
            let Ok(Message::Request { id, method: m, params }) = Message::parse(&text) else {
                continue;
            };
            let reply = if m == method::SESSION_NEW {
                received_tx.send(params.unwrap_or_default()).await.unwrap();
                Message::err(
                    id,
                    acpmux::rpc::RpcError::invalid_params("policy refused").with_data(json!({
                        "reason": "remote.policy_refused", "servedAs": "remote"
                    })),
                )
            } else {
                let result = if m == method::INITIALIZE {
                    json!({"protocolVersion": 1, "_meta": {"acpmux": {
                        "version": "0", "build": "test", "origin": "peer",
                        "features": ["trustGate"]}}})
                } else {
                    json!({})
                };
                Message::ok(id, result)
            };
            ws.send(Ws::Text(reply.to_line().into())).await.unwrap();
        }
    });
    let a = hub(&root);
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), None, None, true).await.unwrap();
    let mut ca = C::open(&a, Origin::Local);
    let r = ca
        .call(
            method::SESSION_NEW,
            new(
                json!({"peer": "b", "harness": "fake", "policy": "approve-all",
                    "tags": {"a": "b"}, "ephemeral": true,
                    "argv": ["new", "--host", "b", "--prompt-file", "brief.md", "inline prompt"],
                    "promptFileText": "file prompt"}),
                Some(&root),
            ),
        )
        .await;
    assert_eq!(reason(&r), "remote.policy_refused");
    let received = received_rx.recv().await.unwrap();
    let meta = &received["_meta"]["acpmux"];
    for key in ["argv", "promptFileText", "peer", "ephemeral"] {
        assert!(meta.get(key).is_none(), "forwarded {key}: {received}");
    }
    assert_eq!(meta["tags"], json!({"a": "b"}));
    // The forwarding daemon still has both inputs to build a complete retry.
    let retry = tried(&r);
    assert!(retry.contains("'inline prompt'"), "{retry}");
    assert!(retry.contains("printf %s 'file prompt'"), "{retry}");
    assert!(retry.contains("--prompt-file=/dev/stdin"), "{retry}");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn approve_all_refused_by_a_peer_that_serves_us_as_web_says_to_run_it_on_that_host() {
    let root = scratch("policy");
    let (a, b) = pair("policy", false, &root).await;
    let mut ca = C::open(&a, Origin::Local);
    let meta = json!({"peer": "b", "harness": "fake", "name": "lane-1", "policy": "approve-all"});
    let r = ca.call(method::SESSION_NEW, new(meta, Some(&root))).await;
    assert_eq!(reason(&r), "remote.policy_refused", "{r}");
    assert_eq!(r["error"]["data"]["host"], "b", "{r}");
    // A `ws://` peer may have no ssh: the command is for B itself (an `ssh://` peer's goes
    // through `ssh -- DEST`, unit tested in `remote_new_hint.rs`).
    assert_eq!(r["error"]["data"]["runOn"], "b", "{r}");
    let want = format!(
        "mkdir -p {0} && acpmux new -m fake -n lane-1 --cwd {0} --policy approve-all -d",
        root.display()
    );
    assert_eq!(tried(&r), want, "{r}");
    assert!(r["error"]["message"].as_str().unwrap().contains(&want), "{r}");

    // That command is B's own CLI on B: the unix socket, where approve-all is accepted.
    let mut cb = C::open(&b, Origin::Local);
    let on_b = json!({"harness": "fake", "name": "lane-1", "policy": "approve-all"});
    let r = cb.call(method::SESSION_NEW, new(on_b, Some(&root))).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}"));
    assert_eq!(b.resolve(id).unwrap().meta().permission_policy.as_deref(), Some("approve-all"));
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_mode_refused_at_a_remote_start_says_to_start_without_it_and_that_start_works() {
    let root = scratch("mode");
    let (a, _b) = pair("mode", true, &root).await;
    let mut ca = C::open(&a, Origin::Local);
    let meta = json!({"peer": "b", "harness": "fake", "name": "lane-2", "mode": "yolo"});
    let r = ca.call(method::SESSION_NEW, new(meta, Some(&root))).await;
    assert_eq!(reason(&r), "remote.mode_refused", "{r}");
    let want = format!("acpmux new --host b -m fake -n lane-2 --cwd {} -d", root.display());
    assert_eq!(tried(&r), want, "{r}");

    let meta = json!({"peer": "b", "harness": "fake", "name": "lane-2"});
    let r = ca.call(method::SESSION_NEW, new(meta, Some(&root))).await;
    assert!(r["result"]["sessionId"].is_string(), "{r}");
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_mode_and_a_folder_outside_the_roots_are_both_fixed_by_one_suggestion() {
    let root = scratch("both");
    let outside = scratch("both-outside");
    let (a, b) = pair("both", true, &root).await;
    let mut ca = C::open(&a, Origin::Local);
    let meta = json!({"peer": "b", "harness": "fake", "name": "lane-4", "mode": "yolo"});
    let r = ca.call(method::SESSION_NEW, new(meta, Some(&outside.join("w")))).await;
    assert_eq!(reason(&r), "remote.cwd_outside_roots", "{r}");
    let inside = root.join("w");
    let want = format!("acpmux new --host b -m fake -n lane-4 --cwd {} -d", inside.display());
    assert_eq!(tried(&r), want, "{r}");

    let meta = json!({"peer": "b", "harness": "fake", "name": "lane-4"});
    let r = ca.call(method::SESSION_NEW, new(meta, Some(&inside))).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}"));
    assert!(b.sessions().iter().any(|s| s.id == id && s.meta().cwd == inside));
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&outside);
}

/// The documented rule (acpmux skill §6): `--policy approve-all` at a remote start passes
/// when the peer serves this daemon as a peer (`servedAs` in `acpmux --json host ls`), and
/// only then. What `host ls` shows and what the peer decides agree over a real link: a peer
/// on a build from before #24442 showed `servedAs: peer` and still refused it (cosmic-gray to
/// gcp-agent-lane-1, 2026-10-25), which `acpmux host update` fixes.
#[tokio::test]
async fn approve_all_at_a_remote_start_passes_exactly_when_host_ls_shows_served_as_peer() {
    for (tag, as_peer) in [("served-peer", true), ("served-remote", false)] {
        let root = scratch(tag);
        let (a, b) = pair(tag, as_peer, &root).await;
        let served = a.peers()[0]["servedAs"].clone();
        assert_eq!(served, if as_peer { "peer" } else { "remote" }, "{:?}", a.peers());
        let mut ca = C::open(&a, Origin::Local);
        let name = format!("lane-{tag}");
        let meta = json!({"peer": "b", "harness": "fake", "name": name, "policy": "approve-all"});
        let r = ca.call(method::SESSION_NEW, new(meta, Some(&root))).await;
        if as_peer {
            assert!(r["result"]["sessionId"].is_string(), "{r}");
            let on_b = b.resolve(&name).unwrap_or_else(|e| panic!("{name} on b: {e:?} ({r})"));
            assert_eq!(on_b.meta().permission_policy.as_deref(), Some("approve-all"), "{r}");
        } else {
            assert_eq!(reason(&r), "remote.policy_refused", "{r}");
            assert_eq!(r["error"]["data"]["servedAs"], served, "{r}");
            assert!(b.resolve(&name).is_err(), "a refused start leaves no session on b");
        }
        let _ = std::fs::remove_dir_all(&root);
    }
}
