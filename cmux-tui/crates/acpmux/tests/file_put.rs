//! A file the person drops into a chat that the composer can't attach as a block lands on the
//! machine that runs the chat (`_acpmux/file_put`, `hub/file_uploads.rs`): owner-only under the
//! daemon's `uploads` folder, answered with its path. A chat on an ssh peer gets it there, through
//! the daemon the app talks to; a peer that does not take it is refused before anything is sent,
//! and no request larger than an older peer's frame limit crosses the link. Web connections never
//! save one.

// Unix only: the owner-only modes are Unix's.
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
use base64::Engine;
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const MAX: usize = 10 << 20;

/// The home every test here shares (the process's, set once).
fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home = std::env::temp_dir().join(format!("acpmux-file-put-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        acpmux::config::set_home_override(home.clone());
        home
    })
}

fn hub() -> Arc<Hub> {
    home();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    async fn new_session(&mut self, name: &str) -> String {
        let made = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned()
    }
}

fn put(session: &str, name: &str, bytes: &[u8]) -> Value {
    json!({"sessionId": session, "fileName": name,
           "data": base64::engine::general_purpose::STANDARD.encode(bytes)})
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// The file the reply names: its bytes, owner-only in an owner-only folder of its own under the
/// session's uploads.
fn assert_saved(reply: &Value, session: &str, name: &str, bytes: &[u8]) -> PathBuf {
    let path = PathBuf::from(reply["result"]["path"].as_str().unwrap_or_else(|| panic!("{reply}")));
    assert_eq!(path.file_name().unwrap().to_str(), Some(name), "{reply}");
    let folder = path.parent().unwrap();
    assert_eq!(folder.parent().unwrap(), home().join("uploads").join(session), "{reply}");
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(folder), 0o700);
    assert_eq!(mode(folder.parent().unwrap()), 0o700);
    path
}

#[tokio::test]
async fn a_dropped_file_is_saved_owner_only_and_named_by_its_path() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("drop").await;
    let binary = [0u8, 1, 2, 0xff];
    let first = c.call(method::MUX_FILE_PUT, put(&session, "state.sqlite", &binary)).await;
    let first = assert_saved(&first, &session, "state.sqlite", &binary);
    // The same name again keeps both.
    let second = c.call(method::MUX_FILE_PUT, put(&session, "state.sqlite", b"b")).await;
    let second = assert_saved(&second, &session, "state.sqlite", b"b");
    assert_ne!(first, second);
    assert_eq!(std::fs::read(&first).unwrap(), binary);
    // The largest file there is.
    let largest = vec![7u8; MAX];
    let reply = c.call(method::MUX_FILE_PUT, put(&session, "big.bin", &largest)).await;
    assert_saved(&reply, &session, "big.bin", &largest);
    // The app's pane connection saves one too.
    let mut app = client(&hub, Origin::LocalApp);
    let reply = app.call(method::MUX_FILE_PUT, put(&session, "app.txt", b"x")).await;
    assert_saved(&reply, &session, "app.txt", b"x");
}

#[tokio::test]
async fn a_bad_name_an_oversize_file_an_unknown_chat_and_the_web_are_refused() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("refusals").await;
    for name in [".env", "a/b", "..", "", "a\u{202e}txt", "a\nb"] {
        let reply = c.call(method::MUX_FILE_PUT, put(&session, name, b"x")).await;
        assert_eq!(reply["error"]["data"]["reason"], "filePut.name", "{name:?}: {reply}");
    }
    let reply = c.call(method::MUX_FILE_PUT, put(&session, "big.bin", &vec![0u8; MAX + 1])).await;
    assert_eq!(reply["error"]["data"]["reason"], "filePut.tooLarge", "{reply}");
    let reply = c.call(method::MUX_FILE_PUT, put("no-such-chat", "a.txt", b"x")).await;
    assert!(reply.get("error").is_some(), "{reply}");
    let mut web = client(&hub, Origin::Web);
    let reply = web.call(method::MUX_FILE_PUT, put(&session, "a.txt", b"x")).await;
    assert_eq!(reply["error"]["data"]["reason"], "filePut.remote", "{reply}");
    // Nothing of these was saved.
    let saved = std::fs::read_dir(home().join("uploads").join(&session)).map_or(0, Iterator::count);
    assert_eq!(saved, 0);
}

/// A deleted chat's files go with it: nothing else ever deleted them, so every file dropped into
/// every chat stayed in the daemon's home for good.
#[tokio::test]
async fn a_purged_chat_loses_its_files_and_takes_no_more() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("purged").await;
    let reply = c.call(method::MUX_FILE_PUT, put(&session, "a.txt", b"x")).await;
    assert_saved(&reply, &session, "a.txt", b"x");
    let kept = c.new_session("kept").await;
    let reply = c.call(method::MUX_FILE_PUT, put(&kept, "b.txt", b"y")).await;
    let kept_file = assert_saved(&reply, &kept, "b.txt", b"y");
    let killed = c.call(method::MUX_KILL, json!({"sessionId": session, "purge": true})).await;
    assert!(killed.get("error").is_none(), "{killed}");
    assert!(!home().join("uploads").join(&session).exists(), "the deleted chat's uploads stayed");
    // Another chat's files stay, and so do a closed chat's (kill without purge).
    let closed = c.call(method::MUX_KILL, json!({"sessionId": kept})).await;
    assert!(closed.get("error").is_none(), "{closed}");
    assert_eq!(std::fs::read(&kept_file).unwrap(), b"y");
    // A chat that is gone takes no more.
    let reply = c.call(method::MUX_FILE_PUT, put(&session, "b.txt", b"x")).await;
    assert!(reply.get("error").is_some(), "{reply}");
}

/// Moves chat `id` from `src` to `dst` (`_acpmux/transfer_*`, as the app's Move and Bring Back
/// do) and retires it on `src`.
async fn transfer(src: &mut Client, dst: &mut Client, id: &str) {
    let begin = src.call("_acpmux/transfer_begin", json!({"sessionId": id})).await;
    let begin = begin["result"].clone();
    let received = dst.call("_acpmux/transfer_receive", json!({"manifest": begin})).await;
    let receive_id =
        received["result"]["receiveId"].as_str().unwrap_or_else(|| panic!("{received}"));
    for file in begin["files"].as_array().unwrap_or_else(|| panic!("{begin}")) {
        let path = file["path"].as_str().unwrap();
        let mut offset = 0u64;
        loop {
            let part = src
                .call(
                    "_acpmux/transfer_read",
                    json!({"transferId": begin["transferId"], "path": path, "offset": offset, "limit": 1 << 16}),
                )
                .await;
            let part = &part["result"];
            let wrote = dst
                .call(
                    "_acpmux/transfer_write",
                    json!({"receiveId": receive_id, "path": path, "offset": offset, "data": part["data"]}),
                )
                .await;
            assert!(wrote.get("error").is_none(), "{wrote}");
            offset = part["next"].as_u64().unwrap_or_else(|| panic!("{part}"));
            if part["eof"] == true {
                break;
            }
        }
    }
    let finished = dst.call("_acpmux/transfer_finish", json!({"receiveId": receive_id})).await;
    assert_eq!(finished["result"]["sessionId"], id, "{finished}");
    let committed = src
        .call(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begin["transferId"], "to": {"sessionId": id}}),
        )
        .await;
    assert_eq!(committed["result"]["committed"], true, "{committed}");
}

/// A chat moved away and brought back replaces its closed copy under the same id: the files its
/// prompts name stay. Deleting the chat then deletes them.
#[tokio::test]
async fn a_chat_brought_back_keeps_its_files() {
    let (here, there) = (hub(), hub());
    let mut a = client(&here, Origin::Local);
    let mut b = client(&there, Origin::Local);
    let id = a.new_session("round-trip").await;
    let reply = a.call(method::MUX_FILE_PUT, put(&id, "a.txt", b"x")).await;
    let file = assert_saved(&reply, &id, "a.txt", b"x");
    transfer(&mut a, &mut b, &id).await;
    transfer(&mut b, &mut a, &id).await;
    assert_eq!(
        std::fs::read(&file).ok().as_deref(),
        Some(&b"x"[..]),
        "the returning chat's file went"
    );
    let killed = a.call(method::MUX_KILL, json!({"sessionId": id, "purge": true})).await;
    assert!(killed.get("error").is_none(), "{killed}");
    assert!(!home().join("uploads").join(&id).exists(), "the deleted chat's uploads stayed");
}

/// B's WebSocket listener with a peer token; returns its port and the token.
async fn listen_with_peer_token(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let dir = std::env::temp_dir().join(format!("file-put-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let auth = PeerAuth::create(&dir).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

#[tokio::test]
async fn a_file_for_a_peers_chat_lands_on_the_peer() {
    // B owns the chat; A, the daemon the app talks to, mirrors B as a peer.
    let b = hub();
    let (port, peer_token) = listen_with_peer_token(b.clone(), "peer").await;
    let mut cb = client(&b, Origin::Local);
    let remote = cb.new_session("far").await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    let reply = ca.call(method::MUX_FILE_PUT, put(&remote, "notes.bin", b"\x00far")).await;
    assert_eq!(reply["result"]["peer"], "b", "{reply}");
    assert_saved(&reply, &remote, "notes.bin", b"\x00far");
    // The largest file fits the link's frame: it arrives, and the link stays up.
    let largest = vec![9u8; MAX];
    let reply = ca.call(method::MUX_FILE_PUT, put(&remote, "big.bin", &largest)).await;
    assert_saved(&reply, &remote, "big.bin", &largest);
    // One past it is refused by A, never sent: the link and its chats stay up.
    let reply = ca.call(method::MUX_FILE_PUT, put(&remote, "big.bin", &vec![0u8; MAX + 1])).await;
    assert_eq!(reply["error"]["data"]["reason"], "filePut.tooLarge", "{reply}");
    let reply = ca.call(method::MUX_FILE_PUT, put(&remote, "after.txt", b"ok")).await;
    assert_saved(&reply, &remote, "after.txt", b"ok");
    assert_eq!(a.peers()[0]["connected"], true, "{:?}", a.peers());
}

/// A TCP relay in front of `port` that, while `up` is false, drops every connection it carries
/// and refuses new ones (accepts and closes them), as an ssh tunnel to a loaded host does.
async fn cuttable_relay(port: u16, up: tokio::sync::watch::Receiver<bool>) -> u16 {
    async fn pipe(
        mut from: tokio::net::tcp::OwnedReadHalf,
        mut to: tokio::net::tcp::OwnedWriteHalf,
        mut up: tokio::sync::watch::Receiver<bool>,
    ) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            // The read guard of `up` never lives across an await: the pipe ends once it reads false.
            if !*up.borrow_and_update() {
                return;
            }
            let n = tokio::select! {
                read = from.read(&mut buf) => match read {
                    Ok(n) if n > 0 => n,
                    _ => return,
                },
                changed = up.changed() => {
                    if changed.is_err() {
                        return;
                    }
                    continue;
                }
            };
            if to.write_all(&buf[..n]).await.is_err() {
                return;
            }
        }
    }
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((client, _)) = l.accept().await {
            if !*up.borrow() {
                continue;
            }
            let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await else {
                continue;
            };
            let (cr, cw) = client.into_split();
            let (sr, sw) = server.into_split();
            tokio::spawn(pipe(sr, cw, up.clone()));
            tokio::spawn(pipe(cr, sw, up.clone()));
        }
    });
    relay_port
}

/// Leo, 2026-11-01: a pasted video for a chat on a lane VM failed on its first try while the ssh
/// link to that VM was reconnecting (`peer_unreachable ... SSH connection refused` in the app's
/// daemon log), and only his Retry got it through: "i had to retry to get it to load???". A file
/// sent while the peer's link is down waits for it to come back, and lands.
#[tokio::test]
async fn a_file_sent_while_the_peers_link_reconnects_waits_for_it_and_lands() {
    let b = hub();
    let (port, peer_token) = listen_with_peer_token(b.clone(), "reconnect").await;
    let mut cb = client(&b, Origin::Local);
    let remote = cb.new_session("far-reconnect").await;
    let (up, link) = tokio::sync::watch::channel(true);
    let relay = cuttable_relay(port, link).await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{relay}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    assert_eq!(a.peers()[0]["connected"], true, "{:?}", a.peers());
    // The link drops and stays down for a moment.
    up.send_replace(false);
    tokio::time::timeout(Duration::from_secs(10), async {
        while a.peers()[0]["connected"] == true {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the cut link must go down");
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(1500)).await;
        up.send_replace(true);
    });
    let mut ca = client(&a, Origin::Local);
    let reply = ca.call(method::MUX_FILE_PUT, put(&remote, "clip.mp4", b"video bytes")).await;
    assert_eq!(reply["result"]["peer"], "b", "it waited for the link instead of failing: {reply}");
    assert_saved(&reply, &remote, "clip.mp4", b"video bytes");
}

/// A peer from before `_acpmux/file_put` (it lists no `filePut` feature): a WebSocket server that
/// lists one session and counts the file puts it gets. Returns its port.
async fn older_peer(puts: Arc<AtomicUsize>) -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let puts = puts.clone();
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "older", "origin": "peer",
                            "features": ["trustGate"]}}}),
                        method::MUX_WATCH => {
                            json!({"sessions": [{"sessionId": "old-1", "name": "old"}]})
                        }
                        method::MUX_FILE_PUT => {
                            puts.fetch_add(1, Ordering::SeqCst);
                            json!({})
                        }
                        _ => json!({}),
                    };
                    let reply = Message::ok(id, result).to_line();
                    if ws.send(Ws::Text(reply.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    port
}

#[tokio::test]
async fn a_peer_that_does_not_take_files_is_refused_before_anything_is_sent() {
    let puts = Arc::new(AtomicUsize::new(0));
    let port = older_peer(puts.clone()).await;
    let a = hub();
    a.add_peer("old", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    let reply = ca.call(method::MUX_FILE_PUT, put("old-1", "a.txt", b"x")).await;
    assert_eq!(reply["error"]["code"], -32601, "{reply}");
    assert_eq!(reply["error"]["data"]["reason"], "filePut.unsupported", "{reply}");
    assert_eq!(puts.load(Ordering::SeqCst), 0);
}

/// The daemon says it takes files, so the app asks only one that does.
#[tokio::test]
async fn initialize_lists_the_file_put_feature() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let init = c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await;
    let features = init["result"]["_meta"]["acpmux"]["features"].as_array().unwrap();
    assert!(features.contains(&json!("filePut")), "{init}");
    let extensions = init["result"]["_meta"]["acpmux"]["extensions"].as_array().unwrap();
    assert!(extensions.contains(&json!("_acpmux/file_put")), "{init}");
}
