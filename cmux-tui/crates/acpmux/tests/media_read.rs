//! The hub's media reader (`_acpmux/media_open`, `_acpmux/media_range`, `hub/media_read.rs`): a
//! chat's images and videos are read on the machine that runs the chat, from the chat's folder or
//! its uploads, by ranges that each repeat the open's size and identity. A peer's chat is read on
//! the peer, and only a peer that lists `mediaRead` is asked. A Web connection reads nothing.

// Unix only: the reader opens through `openat`.
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
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home = std::env::temp_dir().join(format!("acpmux-media-read-{}", std::process::id()));
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

/// A chat folder with `out/shot.png` and `out/clip.mp4`.
fn chat_folder(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-media-chat-{}/{tag}", std::process::id()));
    std::fs::create_dir_all(dir.join("out")).unwrap();
    std::fs::write(dir.join("out/shot.png"), shot()).unwrap();
    std::fs::write(dir.join("out/clip.mp4"), clip()).unwrap();
    dir
}

fn shot() -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    bytes.resize(300, 3);
    bytes
}

fn clip() -> Vec<u8> {
    let mut bytes = b"\0\0\0\x18ftypisom\0\0\x02\0isomiso2".to_vec();
    bytes.resize(1000, 5);
    bytes
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

    async fn new_session(&mut self, name: &str, cwd: &Path) -> String {
        let made = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned()
    }

    async fn open(&mut self, session: &str, path: &str) -> Value {
        self.call(method::MUX_MEDIA_OPEN, json!({"sessionId": session, "path": path})).await
    }

    async fn range(&mut self, session: &str, handle: &Value, offset: u64, length: u64) -> Value {
        let params =
            json!({"sessionId": session, "handle": handle, "offset": offset, "length": length});
        self.call(method::MUX_MEDIA_RANGE, params).await
    }

    /// Opens `path` and reads it whole in ranges of `step` bytes, checking every reply.
    async fn read(&mut self, session: &str, path: &str, step: u64) -> (String, Vec<u8>) {
        let opened = self.open(session, path).await;
        let open = &opened["result"];
        let size = open["size"].as_u64().unwrap_or_else(|| panic!("{opened}"));
        let mut bytes = Vec::new();
        while (bytes.len() as u64) < size {
            let offset = bytes.len() as u64;
            let reply = self.range(session, &open["handle"], offset, step).await;
            let part = &reply["result"];
            assert_eq!(part["offset"], offset, "{reply}");
            assert_eq!(part["size"], size, "{reply}");
            assert_eq!(part["identity"], open["identity"], "{reply}");
            let data = part["data"].as_str().unwrap_or_else(|| panic!("{reply}"));
            bytes.extend(base64::engine::general_purpose::STANDARD.decode(data).unwrap());
        }
        // The final range closed the handle.
        let after = self.range(session, &open["handle"], 0, 1).await;
        assert_eq!(after["error"]["data"]["reason"], "media.handle", "{after}");
        (open["mimeType"].as_str().unwrap_or_default().to_owned(), bytes)
    }
}

fn reason(reply: &Value) -> &str {
    reply["error"]["data"]["reason"].as_str().unwrap_or_else(|| panic!("not refused: {reply}"))
}

#[tokio::test]
async fn media_a_chat_reads_its_folder_and_its_uploads_by_range() {
    let hub = hub();
    let folder = chat_folder("local");
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("media", &folder).await;
    assert_eq!(c.read(&session, "out/shot.png", 128).await, ("image/png".into(), shot()));
    let absolute = folder.join("out/clip.mp4");
    let read = c.read(&session, &absolute.to_string_lossy(), 1 << 20).await;
    assert_eq!(read, ("video/mp4".into(), clip()));
    // A file dropped into the chat is read from its uploads, by the path `file_put` answered.
    let put = json!({"sessionId": session, "fileName": "drop.png",
                     "data": base64::engine::general_purpose::STANDARD.encode(shot())});
    let put = c.call(method::MUX_FILE_PUT, put).await;
    let saved = put["result"]["path"].as_str().unwrap_or_else(|| panic!("{put}")).to_owned();
    assert_eq!(c.read(&session, &saved, 100).await, ("image/png".into(), shot()));
    // The app's pane connection reads too.
    let mut app = client(&hub, Origin::LocalApp);
    assert_eq!(app.read(&session, "out/shot.png", 300).await.1, shot());
}

#[tokio::test]
async fn media_the_web_another_chats_handle_a_bad_range_and_other_files_are_refused() {
    let hub = hub();
    let folder = chat_folder("refusals");
    std::fs::write(folder.join("notes.txt"), b"plain text").unwrap();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("refusals", &folder).await;
    let other = c.new_session("other", &chat_folder("other")).await;
    let mut web = client(&hub, Origin::Web);
    assert_eq!(reason(&web.open(&session, "out/shot.png").await), "mediaRead.remote");
    for (path, why) in [
        ("out/../../other/out/shot.png", "media.path"),
        ("notes.txt", "media.type"),
        ("/etc/hosts", "media.outside"),
    ] {
        assert_eq!(reason(&c.open(&session, path).await), why, "{path}");
    }
    let opened = c.open(&session, "out/clip.mp4").await;
    let handle = &opened["result"]["handle"];
    assert_eq!(reason(&web.range(&session, handle, 0, 10).await), "mediaRead.remote");
    assert_eq!(reason(&c.range(&other, handle, 0, 10).await), "media.handle");
    assert_eq!(reason(&c.range(&session, handle, 0, (6 << 20) + 1).await), "media.range");
    // A refused range closes its handle: the reader opens the file again.
    assert_eq!(reason(&c.range(&session, handle, 0, 10).await), "media.handle");
    let opened = c.open(&session, "out/clip.mp4").await;
    let handle = &opened["result"]["handle"];
    assert_eq!(reason(&c.range(&session, handle, 1000, 1).await), "media.range");
    let opened = c.open(&session, "out/clip.mp4").await;
    let handle = &opened["result"]["handle"];
    // Another connection does not share this one's handles.
    let mut second = client(&hub, Origin::Local);
    assert_eq!(reason(&second.range(&session, handle, 0, 10).await), "media.handle");
    let part = c.range(&session, handle, 0, 10).await;
    assert_eq!(part["result"]["offset"], 0, "{part}");
}

#[tokio::test]
async fn media_of_a_peers_chat_is_read_on_the_peer() {
    let b = hub();
    let dir = home().join(format!("media-peer-{}", std::process::id()));
    let auth = PeerAuth::create(&dir).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), auth));
    let folder = chat_folder("peer");
    let mut cb = client(&b, Origin::Local);
    let remote = cb.new_session("far", &folder).await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    let opened = ca.open(&remote, "out/clip.mp4").await;
    assert_eq!(opened["result"]["peer"], "b", "{opened}");
    assert_eq!(ca.read(&remote, "out/clip.mp4", 400).await, ("video/mp4".into(), clip()));
    // The link carries every client's reads: a handle is its own client's, and one client's
    // full table leaves room on the link for another's.
    // The open above is still held: it counts as one of this client's places.
    let mut held = vec![opened["result"]["handle"].clone()];
    while held.len() < acpmux::hub::media_handles::MAX_HANDLES {
        let opened = ca.open(&remote, "out/clip.mp4").await;
        assert!(opened["result"]["handle"].is_string(), "{opened}");
        held.push(opened["result"]["handle"].clone());
    }
    assert_eq!(reason(&ca.open(&remote, "out/clip.mp4").await), "media.handles");
    let mut other = client(&a, Origin::Local);
    assert_eq!(reason(&other.range(&remote, &held[0], 0, 10).await), "media.handle");
    let theirs = other.open(&remote, "out/clip.mp4").await;
    assert_eq!(theirs["result"]["size"], clip().len(), "{theirs}");
    assert_eq!(ca.range(&remote, &held[0], 0, 10).await["result"]["offset"], 0);
}

/// A range the peer refuses before its reader sees it (here its guard: the local client asks for a
/// device's Full access, which no device proved) still closes the handle there. Otherwise each
/// such range would leave one of the link's places taken, and opens enough times over would
/// fill the peer.
#[tokio::test]
async fn media_a_range_the_peer_refuses_early_still_closes_its_handle_there() {
    let b = hub();
    let dir = home().join(format!("media-peer-refused-{}", std::process::id()));
    let auth = PeerAuth::create(&dir).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), auth));
    let mut cb = client(&b, Origin::Local);
    let remote = cb.new_session("far-refused", &chat_folder("peer-refused")).await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    for round in 0..=acpmux::hub::media_handles::MAX_OPEN {
        let opened = ca.open(&remote, "out/clip.mp4").await;
        let handle = &opened["result"]["handle"];
        assert!(handle.is_string(), "round {round}: {opened}");
        let params = json!({"sessionId": remote, "handle": handle, "offset": 0, "length": 10,
                            "_meta": {"acpmux": {"requireFullAccess": true}}});
        let refused = ca.call(method::MUX_MEDIA_RANGE, params).await;
        assert!(refused.get("error").is_some(), "round {round}: {refused}");
    }
}

/// A peer from before the reader (it lists no `mediaRead`): it counts the media calls it gets.
async fn older_peer(calls: Arc<AtomicUsize>) -> u16 {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let calls = calls.clone();
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "version": "0", "build": "older", "origin": "peer",
                            "features": ["trustGate", "filePut"]}}}),
                        method::MUX_WATCH => {
                            json!({"sessions": [{"sessionId": "old-1", "name": "old"}]})
                        }
                        method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE => {
                            calls.fetch_add(1, Ordering::SeqCst);
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
async fn media_reads_of_a_peer_without_the_reader_are_refused_before_anything_is_sent() {
    let calls = Arc::new(AtomicUsize::new(0));
    let port = older_peer(calls.clone()).await;
    let a = hub();
    a.add_peer("old", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    let reply = ca.open("old-1", "out/shot.png").await;
    assert_eq!(reply["error"]["code"], -32601, "{reply}");
    assert_eq!(reason(&reply), "mediaRead.unsupported");
    let reply = ca.range("old-1", &json!("h"), 0, 1).await;
    assert_eq!(reason(&reply), "mediaRead.unsupported");
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}
