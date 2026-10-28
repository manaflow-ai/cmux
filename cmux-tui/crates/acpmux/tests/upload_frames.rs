//! Binary upload frames (`server/upload_frames.rs`, `docs/prompt-uploads.md` section 1): the app
//! streams a file's raw bytes on its own WebSocket, pipelined up to 4 frames, resumes after a
//! disconnect from `_acpmux/file_put_status`, and the finish checks the SHA-256. Any other
//! connection is answered with a refusal, never silence. A peer's chat gets the bytes written on
//! the peer. The 2 GB file: `prompt_uploads_large.rs`.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

#[path = "support/app_ws.rs"]
mod app_ws;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
use app_ws::AppWs;
use serde_json::{Value, json};
use sha2::Digest;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const MIB: usize = 1 << 20;
const STATUS: &str = "_acpmux/file_put_status";

fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home =
            std::env::temp_dir().join(format!("acpmux-upload-frames-{}", std::process::id()));
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

/// A chat named `name` on `hub`, made over its unix-socket-like in-process connection.
async fn new_session(hub: &Arc<Hub>, name: &str) -> String {
    let (tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut rx) = mpsc::channel::<String>(256);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let p =
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}});
    tx.send(Message::request(1, method::SESSION_NEW, p).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{v}")).to_owned();
        }
    }
}

fn bytes(n: usize, seed: u8) -> Vec<u8> {
    (0..n).map(|i| (i as u8).wrapping_mul(31) ^ seed ^ (i >> 16) as u8).collect()
}

fn sha(bytes: &[u8]) -> String {
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

async fn begin(c: &mut AppWs, session: &str, name: &str, size: u64) -> Value {
    c.call(
        method::MUX_FILE_PUT_BEGIN,
        json!({"sessionId": session, "fileName": name, "size": size}),
    )
    .await
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or("none")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_file_streams_as_binary_frames_resumes_after_a_disconnect_and_is_checked() {
    let hub = hub();
    let l = app_ws::listen(&hub).await;
    let session = new_session(&hub, "frames").await;
    let mut c = AppWs::open(&l, true).await;
    assert_eq!(c.init["result"]["_meta"]["acpmux"]["auth"], "localApp", "{}", c.init);
    let features = c.init["result"]["_meta"]["acpmux"]["features"].clone();
    assert!(features.as_array().unwrap().contains(&json!("uploadFrames")), "{features}");

    let file = bytes(6 * MIB + 123, 1);
    let begun = begin(&mut c, &session, "data.bin", file.len() as u64).await;
    let upload = begun["result"]["uploadId"].as_str().unwrap_or_else(|| panic!("{begun}"));
    let upload = upload.to_owned();
    let frames: Vec<&[u8]> = file.chunks(MIB).collect();

    // Two frames in flight, answered in order once on disk; then the connection drops.
    let ids = [
        c.frame(&session, &upload, 0, frames[0]).await,
        c.frame(&session, &upload, MIB as u64, frames[1]).await,
    ];
    for (n, id) in ids.into_iter().enumerate() {
        let a = c.answer(id).await;
        assert_eq!(a["result"]["offset"], json!((n + 1) * MIB), "{a}");
    }
    drop(c);

    // A new connection reads where the upload stands and resumes there.
    let mut c = AppWs::open(&l, true).await;
    let at = c.call(STATUS, json!({"sessionId": session, "uploadId": upload})).await;
    assert_eq!(at["result"]["offset"], json!(2 * MIB), "{at}");
    assert_eq!(at["result"]["finished"], false, "{at}");
    assert_eq!(at["result"]["size"], json!(file.len()), "{at}");
    let stale = c.frame(&session, &upload, 0, frames[0]).await;
    let stale = c.answer(stale).await;
    assert_eq!(reason(&stale), "upload.offset", "{stale}");
    assert_eq!(stale["error"]["data"]["offset"], json!(2 * MIB), "{stale}");
    // The rest, four frames in flight (the window), each answered in order.
    let mut ids = Vec::new();
    for (n, f) in frames.iter().enumerate().skip(2) {
        ids.push((n, c.frame(&session, &upload, (n * MIB) as u64, f).await));
    }
    for (n, id) in ids {
        let a = c.answer(id).await;
        assert_eq!(a["result"]["offset"], json!((n * MIB + frames[n].len())), "{a}");
    }
    let finish = json!({"sessionId": session, "uploadId": upload, "fileName": "data.bin",
        "size": file.len(), "sha256": sha(&file)});
    let done = c.call(method::MUX_FILE_PUT_FINISH, finish.clone()).await;
    let path = done["result"]["path"].as_str().unwrap_or_else(|| panic!("{done}")).to_owned();
    assert_eq!(sha(&std::fs::read(&path).unwrap()), sha(&file));
    // A finish whose answer was lost is answered again; status says it is finished.
    let again = c.call(method::MUX_FILE_PUT_FINISH, finish).await;
    assert_eq!(again["result"]["path"], json!(path), "{again}");
    let at = c.call(STATUS, json!({"sessionId": session, "uploadId": upload})).await;
    assert_eq!(at["result"]["finished"], true, "{at}");
    assert_eq!(at["result"]["path"], json!(path), "{at}");
}

/// A remote connection's frame is answered with a refusal at once: the sender never waits on
/// silence (the 4 MiB page binding that dropped calls unanswered, 2026-10-26).
#[tokio::test]
async fn a_frame_from_any_other_connection_is_refused_with_an_answer() {
    let hub = hub();
    let l = app_ws::listen(&hub).await;
    let session = new_session(&hub, "web").await;
    let mut web = AppWs::open(&l, false).await;
    assert_ne!(web.init["result"]["_meta"]["acpmux"]["auth"], "localApp", "{}", web.init);
    let id = web.frame(&session, &uuid::Uuid::now_v7().to_string(), 0, b"x").await;
    let refused = web.answer(id).await;
    assert_eq!(reason(&refused), "filePut.remote", "{refused}");
}

/// A peer's chat: frames to this daemon are written on the peer that owns the chat, in chunks
/// over the peer link, and status and finish are the peer's.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_peers_chat_gets_the_frames_written_on_the_peer() {
    let b = hub();
    let dir = std::env::temp_dir().join(format!("upload-frames-peer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let auth = PeerAuth::create(&dir).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let lb = bind_ws("127.0.0.1:0").await.unwrap();
    let port = lb.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), lb, "tok".into(), ws_auth));
    let remote = new_session(&b, "frames-far").await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    let l = app_ws::listen(&a).await;
    let mut c = AppWs::open(&l, true).await;
    let file = bytes(3 * MIB + 7, 2);
    let begun = begin(&mut c, "b/frames-far", "far.bin", file.len() as u64).await;
    let upload = begun["result"]["uploadId"].as_str().unwrap_or_else(|| panic!("{begun}"));
    let upload = upload.to_owned();
    let mut ids = Vec::new();
    for (n, f) in file.chunks(MIB).enumerate() {
        ids.push(c.frame("b/frames-far", &upload, (n * MIB) as u64, f).await);
    }
    for id in ids {
        let a = c.answer(id).await;
        assert!(a.get("error").is_none(), "{a}");
    }
    let at = c.call(STATUS, json!({"sessionId": "b/frames-far", "uploadId": upload})).await;
    assert_eq!(at["result"]["offset"], json!(file.len()), "{at}");
    let finish = json!({"sessionId": "b/frames-far", "uploadId": upload, "fileName": "far.bin",
        "size": file.len(), "sha256": sha(&file)});
    let done = c.call(method::MUX_FILE_PUT_FINISH, finish).await;
    let path = done["result"]["path"].as_str().unwrap_or_else(|| panic!("{done}"));
    assert!(path.contains(&remote), "the peer's own chat folder: {path}");
    assert_eq!(sha(&std::fs::read(path).unwrap()), sha(&file));
}

/// A finish sent right behind the last frames, without waiting for their answers, sees every byte:
/// a text message is read only after the frames before it are written.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_finish_right_behind_its_frames_sees_every_byte() {
    let hub = hub();
    let l = app_ws::listen(&hub).await;
    let session = new_session(&hub, "order").await;
    let mut c = AppWs::open(&l, true).await;
    for round in 0..3u8 {
        let file = bytes(4 * MIB + 5, 10 + round);
        let name = format!("o{round}.bin");
        let begun = begin(&mut c, &session, &name, file.len() as u64).await;
        let upload = begun["result"]["uploadId"].as_str().unwrap_or_else(|| panic!("{begun}"));
        let upload = upload.to_owned();
        let mut ids = Vec::new();
        for (n, f) in file.chunks(MIB).enumerate() {
            ids.push(c.frame(&session, &upload, (n * MIB) as u64, f).await);
        }
        let finish = json!({"sessionId": session, "uploadId": upload, "fileName": name,
            "size": file.len(), "sha256": sha(&file)});
        let done = c.post(method::MUX_FILE_PUT_FINISH, finish).await;
        // Every frame is answered before the finish, which then has all the bytes.
        let answers = c.answers_until(done).await;
        let order: Vec<_> = answers.iter().map(|a| a["id"].clone()).collect();
        let mut want: Vec<_> = ids.iter().map(|id| json!(id)).collect();
        want.push(json!(done));
        assert_eq!(order, want, "{answers:?}");
        let done = answers.last().unwrap();
        let path = done["result"]["path"].as_str().unwrap_or_else(|| panic!("{round}: {done}"));
        assert_eq!(sha(&std::fs::read(path).unwrap()), sha(&file));
    }
}

/// A peer that takes only the one-shot `file_put` (no `filePutChunks`): an upload to its chat is
/// refused at its begin and at its frames, before anything reaches it.
#[tokio::test]
async fn a_peer_without_chunked_uploads_is_refused_before_anything_is_sent() {
    use futures_util::{SinkExt, StreamExt};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let uploads = Arc::new(AtomicUsize::new(0));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let counted = uploads.clone();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let counted = counted.clone();
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
                        m if m.starts_with("_acpmux/file_put") => {
                            counted.fetch_add(1, Ordering::SeqCst);
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
    let a = hub();
    a.add_peer("old", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let l = app_ws::listen(&a).await;
    let mut c = AppWs::open(&l, true).await;
    let begun = begin(&mut c, "old-1", "a.bin", 3).await;
    assert_eq!(reason(&begun), "filePut.unsupported", "{begun}");
    let id = c.frame("old-1", &uuid::Uuid::now_v7().to_string(), 0, b"abc").await;
    let framed = c.answer(id).await;
    assert_eq!(reason(&framed), "filePut.unsupported", "{framed}");
    assert_eq!(uploads.load(Ordering::SeqCst), 0);
}
