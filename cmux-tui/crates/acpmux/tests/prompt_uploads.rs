//! A prompt's files by reference (`src/prompt_uploads.rs`): uploaded first in chunks
//! (`_acpmux/file_put_begin`/`_chunk`/`_finish`), then named in a prompt of a few hundred bytes,
//! so 20 screenshots reach a busy chat with no frame over one MiB (claude-sr2, 2026-10-26: Leo's
//! 8 screenshots in one frame never reached acpmux). The references, their caps, a peer's chat
//! and a peer that cannot read them are checked.
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
use sha2::Digest;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// `hub/file_uploads.rs` `CHUNK_BYTES`.
const CHUNK: usize = 512 << 10;

fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home =
            std::env::temp_dir().join(format!("acpmux-prompt-uploads-{}", std::process::id()));
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

/// A connection; every line it sends is counted in `largest`.
struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    id: i64,
    largest: usize,
    /// Agent text streamed so far.
    text: String,
}

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client { tx: in_tx, rx: out_rx, id: 0, largest: 0, text: String::new() }
}

impl Client {
    async fn post(&mut self, m: &str, params: Value) -> i64 {
        self.id += 1;
        let line = Message::request(self.id, m, params).to_line();
        self.largest = self.largest.max(line.len());
        self.tx.send(line).await.unwrap();
        self.id
    }

    /// The first message `want` takes, keeping the agent text streamed before it.
    async fn until(&mut self, want: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.rx.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if let Some(chunk) =
                value.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                self.text.push_str(chunk);
            }
            if want(&value) {
                return value;
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        self.until(|v| v.get("id") == Some(&json!(id))).await
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

    /// Uploads `bytes` as `name` in chunks; answers its upload id.
    async fn upload(&mut self, session: &str, name: &str, bytes: &[u8]) -> String {
        let begin = json!({"sessionId": session, "fileName": name, "size": bytes.len()});
        let begun = self.call(method::MUX_FILE_PUT_BEGIN, begin).await;
        let id = begun["result"]["uploadId"].as_str().unwrap_or_else(|| panic!("{begun}"));
        let id = id.to_owned();
        for (n, chunk) in bytes.chunks(CHUNK).enumerate() {
            let p = json!({"sessionId": session, "uploadId": id, "offset": n * CHUNK, "data": b64(chunk)});
            let put = self.call(method::MUX_FILE_PUT_CHUNK, p).await;
            assert!(put.get("error").is_none(), "{put}");
        }
        let finish =
            json!({"sessionId": session, "uploadId": id, "fileName": name, "size": bytes.len()});
        let done = self.call(method::MUX_FILE_PUT_FINISH, finish).await;
        assert!(done.get("error").is_none(), "{done}");
        id
    }

    async fn user_messages(&mut self, session: &str) -> Vec<Value> {
        let page = self
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}))
            .await;
        let events = page["result"]["events"].as_array().unwrap_or_else(|| panic!("{page}"));
        events.iter().map(|e| e["msg"].clone()).collect()
    }
}

/// A PNG's bytes (its signature is what the type is read from), `n` long, distinct per `seed`.
fn png(n: usize, seed: u8) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    bytes.push(seed);
    bytes.resize(n.max(bytes.len()), seed);
    bytes
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn sha(bytes: &[u8]) -> String {
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// An image block naming upload `id` of `name`, with no bytes.
fn image_ref(id: &str, name: &str) -> Value {
    json!({"type": "image", "mimeType": "image/png", "name": name,
           "_meta": {"acpmux": {"upload": {"uploadId": id, "fileName": name}}}})
}

fn prompt(session: &str, id: &str, text: &str, files: Vec<Value>) -> Value {
    let mut blocks = vec![json!({"type": "text", "text": text})];
    blocks.extend(files);
    json!({"sessionId": session, "prompt": blocks, "_meta": {"acpmux": {"promptId": id}}})
}

fn v7() -> String {
    uuid::Uuid::now_v7().to_string()
}

/// Leo's case: 20 screenshot-sized images to a chat whose turn runs. No frame is over one MiB, the
/// prompt is taken (queued) in under a second, and the agent gets every image when its turn comes.
#[tokio::test]
async fn twenty_uploaded_screenshots_reach_a_busy_chat_by_reference() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-busy").await;
    c.post(method::SESSION_PROMPT, prompt(&session, "busy", "until-cancel", vec![])).await;
    c.until(|v| v.pointer("/params/update/content/text").is_some()).await;

    let started = Instant::now();
    let shots: Vec<Vec<u8>> = (0..20).map(|n| png(800 << 10, n)).collect();
    let mut refs = Vec::new();
    for (n, shot) in shots.iter().enumerate() {
        let name = format!("shot-{n}.png");
        let id = c.upload(&session, &name, shot).await;
        refs.push(image_ref(&id, &name));
    }
    let id = v7();
    let sent = Instant::now();
    let asked = c.post(method::SESSION_PROMPT, prompt(&session, &id, "look", refs)).await;
    let accepted = c
        .until(|v| {
            (v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == json!(id))
                || v.get("id") == Some(&json!(asked))
        })
        .await;
    let took = sent.elapsed();
    assert_eq!(accepted["params"]["queued"], true, "{accepted}");
    assert!(took < Duration::from_secs(1), "accepted after {took:?}");
    assert!(c.largest < 1 << 20, "a frame of {} bytes", c.largest);
    eprintln!("20 screenshots: uploaded and accepted in {:?}, accept {took:?}", started.elapsed());

    c.post(method::SESSION_CANCEL, json!({"sessionId": session})).await;
    let reply = c.until(|v| v.get("id") == Some(&json!(asked))).await;
    assert!(reply.get("error").is_none(), "{reply}");
    for shot in &shots {
        assert!(c.text.contains(&format!("image:{}", sha(shot))), "missing an image");
    }
    let messages = c.user_messages(&session).await;
    let last = messages.last().unwrap();
    assert_eq!(last["images"].as_array().map(Vec::len), Some(20), "{last}");
    assert_eq!(last["images"][3]["id"], sha(&shots[3]));
}

/// Only a finished upload of the chat's own, of the block's kind, within the caps; never from a
/// remote web client, and never in an edit of a queued prompt. Nothing refused is recorded.
#[tokio::test]
async fn a_reference_outside_the_chats_finished_uploads_is_refused() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let (session, other) = (c.new_session("uploads-own").await, c.new_session("uploads-x").await);
    let theirs = c.upload(&other, "theirs.png", &png(64, 1)).await;
    let text = c.upload(&session, "notes.txt", b"plain words").await;
    let begun = json!({"sessionId": session, "fileName": "half.png", "size": 64});
    let half = c.call(method::MUX_FILE_PUT_BEGIN, begun).await;
    let half = half["result"]["uploadId"].as_str().unwrap().to_owned();
    let mine = c.upload(&session, "mine.png", &png(64, 2)).await;
    let cases = [
        (image_ref(&theirs, "theirs.png"), "upload.missing"),
        (image_ref(&half, "half.png"), "upload.missing"),
        (image_ref(&mine, "../mine.png"), "upload.missing"),
        (image_ref("not-an-id", "mine.png"), "upload.missing"),
        (image_ref(&text, "notes.txt"), "upload.notImage"),
        (
            json!({"type": "text", "text": "x", "_meta": {"acpmux": {"upload": {"uploadId": mine,
            "fileName": "mine.png"}}}}),
            "upload.invalid",
        ),
    ];
    for (block, reason) in cases {
        let reply = c.call(method::SESSION_PROMPT, prompt(&session, &v7(), "x", vec![block])).await;
        assert_eq!(reply["error"]["data"]["reason"], reason, "{reply}");
    }
    let many = (0..33).map(|_| image_ref(&mine, "mine.png")).collect();
    let reply = c.call(method::SESSION_PROMPT, prompt(&session, &v7(), "x", many)).await;
    assert_eq!(reply["error"]["data"]["reason"], "upload.tooMany", "{reply}");
    let mut web = client(&hub, Origin::Web);
    let p = prompt(&session, &v7(), "x", vec![image_ref(&mine, "mine.png")]);
    let reply = web.call(method::SESSION_PROMPT, p).await;
    assert!(reply.get("error").is_some(), "{reply}");
    let edit = json!({"sessionId": session, "promptId": "p", "op": "update",
        "prompt": [{"type": "text", "text": "x"}, image_ref(&mine, "mine.png")]});
    let reply = c.call(method::MUX_QUEUE_EDIT, edit).await;
    assert_eq!(reply["error"]["data"]["reason"], "attach.edit", "{reply}");
    assert!(c.user_messages(&session).await.is_empty());
    // The same reference, sent right, goes; sent again under its prompt id, it runs once.
    let id = v7();
    let p = prompt(&session, &id, "ok", vec![image_ref(&mine, "mine.png")]);
    for _ in 0..2 {
        let reply = c.call(method::SESSION_PROMPT, p.clone()).await;
        assert!(reply.get("error").is_none(), "{reply}");
    }
    assert!(c.text.contains(&format!("image:{}", sha(&png(64, 2)))), "{}", c.text);
    // Its upload gone (the age sweep), the same prompt id still answers with its first run.
    let folder = home().join("uploads").join(&session).join(&mine);
    std::fs::remove_dir_all(folder).unwrap();
    let mut again = p.clone();
    again["_meta"]["acpmux"]["resend"] = json!(true);
    for p in [p, again] {
        let reply = c.call(method::SESSION_PROMPT, p).await;
        assert!(reply.get("error").is_none(), "{reply}");
    }
    assert_eq!(c.user_messages(&session).await.len(), 1);
}

/// One file over 8 MiB, or more than 32 MiB together, is refused; 8 MiB goes.
#[tokio::test]
async fn a_reference_over_a_cap_is_refused() {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-cap").await;
    // A finished upload as `file_put_finish` leaves it, written here to keep the test fast.
    let put = |name: &str, bytes: &[u8]| {
        let id = v7();
        let dir = home().join("uploads").join(&session).join(&id);
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir).unwrap();
        let mut file = std::fs::OpenOptions::new();
        file.write(true).create_new(true).mode(0o600);
        std::io::Write::write_all(&mut file.open(dir.join(name)).unwrap(), bytes).unwrap();
        image_ref(&id, name)
    };
    let big = put("big.png", &png((8 << 20) + 1, 1));
    let reply = c.call(method::SESSION_PROMPT, prompt(&session, &v7(), "x", vec![big])).await;
    assert_eq!(reply["error"]["data"]["reason"], "upload.tooLarge", "{reply}");
    assert!(reply["error"]["message"].as_str().unwrap().contains("8 MiB"), "{reply}");
    let five = (0..5).map(|n| put(&format!("p{n}.png"), &png(7 << 20, n))).collect();
    let reply = c.call(method::SESSION_PROMPT, prompt(&session, &v7(), "x", five)).await;
    assert_eq!(reply["error"]["data"]["reason"], "upload.tooLarge", "{reply}");
    assert!(reply["error"]["message"].as_str().unwrap().contains("32 MiB"), "{reply}");
    assert!(c.user_messages(&session).await.is_empty());
    let max = put("max.png", &png(8 << 20, 7));
    let reply = c.call(method::SESSION_PROMPT, prompt(&session, &v7(), "x", vec![max])).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(c.text.contains(&format!("image:{}", sha(&png(8 << 20, 7)))));
}

/// A chat on a peer: the chunks go over the link to the peer, and the peer resolves the prompt
/// from its own uploads.
#[tokio::test]
async fn a_peers_chat_reads_the_upload_on_the_peer() {
    let b = hub();
    let dir = std::env::temp_dir().join(format!("prompt-uploads-peer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let auth = PeerAuth::create(&dir).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = client(&b, Origin::Local);
    let remote = cb.new_session("uploads-far").await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    let shot = png(700 << 10, 9);
    let id = ca.upload("b/uploads-far", "far.png", &shot).await;
    let p = prompt("b/uploads-far", &v7(), "see", vec![image_ref(&id, "far.png")]);
    let reply = ca.call(method::SESSION_PROMPT, p).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["peer"], "b", "{reply}");
    assert!(ca.text.contains(&format!("image:{}", sha(&shot))), "{}", ca.text);
    let messages = cb.user_messages(&remote).await;
    assert_eq!(messages[0]["images"][0]["id"], sha(&shot), "{messages:?}");
}

/// A peer on a build that does not list `promptUploads` would send its agent an image with no
/// bytes: refused before anything is sent. A peer that lists one session, `old-1`.
#[tokio::test]
async fn a_peer_that_cannot_read_uploads_is_refused_before_anything_is_sent() {
    use futures_util::{SinkExt, StreamExt};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio_tungstenite::tungstenite::Message as Ws;
    let prompts = Arc::new(AtomicUsize::new(0));
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let counted = prompts.clone();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = l.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let counted = counted.clone();
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                        continue;
                    };
                    let result = match m.as_str() {
                        method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {
                            "build": "older", "origin": "peer", "features": ["filePutChunks"]}}}),
                        method::MUX_WATCH => json!({"sessions": [{"sessionId": "old-1"}]}),
                        method::SESSION_PROMPT => {
                            counted.fetch_add(1, Ordering::SeqCst);
                            json!({"stopReason": "end_turn"})
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
    let mut ca = client(&a, Origin::Local);
    let p = prompt("old-1", &v7(), "see", vec![image_ref(&v7(), "a.png")]);
    let reply = ca.call(method::SESSION_PROMPT, p).await;
    assert_eq!(reply["error"]["data"]["reason"], "upload.unsupported", "{reply}");
    assert!(reply["error"]["message"].as_str().unwrap().contains("acpmux host update old"));
    assert_eq!(prompts.load(Ordering::SeqCst), 0);
}
