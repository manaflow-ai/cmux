//! A prompt's files by reference (`src/prompt_uploads.rs`): uploaded first in chunks
//! (`_acpmux/file_put_begin`/`_chunk`/`_finish`), then named in a prompt of a few hundred bytes,
//! so 50 screenshots reach a busy chat with no frame over one MiB (claude-sr2, 2026-10-26: Leo's
//! 8 screenshots in one frame never reached acpmux), with no size or count cap. What the agent
//! gets (inline images within the model's room, every other file by path), a peer's chat and a
//! peer that cannot read them are checked. An upload past the old 1 GiB cap begins.
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
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
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
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"},
            "fakeclaude": {"argv": ["/usr/bin/env", "FAKE_CLAUDE_ECHO=1", "python3", FAKE_CLAUDE],
                "kind": "claude-stdio"}},
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

/// Every record of chat `session`'s log, as JSON, paged through `_acpmux/events`.
async fn whole_log(c: &mut Client, session: &str) -> String {
    let (mut after, mut logged) = (0, String::new());
    loop {
        let all = json!({"sessionId": session, "afterSeq": after, "maxBytes": 4 << 20});
        let page = c.call("_acpmux/events", all).await;
        let records = page["result"]["events"].as_array().unwrap_or_else(|| panic!("{page}"));
        for r in records {
            after = r["seq"].as_u64().unwrap();
            logged.push_str(&r.to_string());
        }
        if page["result"]["hasMore"] != true {
            return logged;
        }
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

/// The resource links in the agent's echo: `(name, path)`.
fn links(text: &str) -> Vec<(String, PathBuf)> {
    text.split_whitespace()
        .filter_map(|word| word.strip_prefix("resource_link:"))
        .filter_map(|link| {
            let (name, rest) = link.split_once(':')?;
            let uri = rest.split_once(':')?.1;
            let path = reqwest::Url::parse(uri).ok()?.to_file_path().ok()?;
            Some((name.to_owned(), path))
        })
        .collect()
}

/// Leo's case: 50 screenshot-sized images to a chat whose turn runs. No frame is over one MiB, the
/// prompt is taken (queued) in under a second, and when its turn comes the agent gets every one,
/// bytes intact: inline while they fit the prompt's room, the rest by the path of their file.
#[tokio::test]
async fn fifty_uploaded_screenshots_reach_a_busy_chat_by_reference() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-busy").await;
    let started = Instant::now();
    let shots: Vec<Vec<u8>> = (0..50).map(|n| png(800 << 10, n)).collect();
    let mut refs = Vec::new();
    for (n, shot) in shots.iter().enumerate() {
        let name = format!("shot-{n}.png");
        let id = c.upload(&session, &name, shot).await;
        refs.push(image_ref(&id, &name));
    }
    // A turn runs (the stand-in's `until-cancel` lasts 30 s at most): the prompt waits behind it.
    c.post(method::SESSION_PROMPT, prompt(&session, "busy", "until-cancel", vec![])).await;
    c.until(|v| v.pointer("/params/update/content/text").is_some()).await;
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
    eprintln!("50 screenshots: uploaded and accepted in {:?}, accept {took:?}", started.elapsed());

    c.post(method::SESSION_CANCEL, json!({"sessionId": session})).await;
    let reply = c.until(|v| v.get("id") == Some(&json!(asked))).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let linked = links(&c.text);
    let mut inline = 0;
    for (n, shot) in shots.iter().enumerate() {
        if c.text.contains(&format!("image:{}", sha(shot))) {
            inline += 1;
            continue;
        }
        let name = format!("shot-{n}.png");
        let (_, path) = linked.iter().find(|(linked, _)| *linked == name).expect(&name);
        assert_eq!(sha(&std::fs::read(path).unwrap()), sha(shot), "{name}");
    }
    // 12 of 800 KiB fit the prompt's 10 MiB of inline room; the agent reads the other 38.
    assert_eq!(inline, 12, "{}", c.text);
    let messages = c.user_messages(&session).await;
    let last = messages.last().unwrap();
    assert_eq!(last["images"].as_array().map(Vec::len), Some(12), "{last}");
    assert_eq!(last["text"], "look", "the note of paths stays out of the transcript: {last}");
}

/// No size cap (Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE"): a
/// 2 GB upload, past the 1 GiB the uploads were capped at, begins and takes its bytes; only the
/// size it began with bounds it.
#[tokio::test]
async fn an_upload_of_any_size_begins_and_takes_its_bytes() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-nocap").await;
    let size = 2_000_000_000u64;
    let begun = c
        .call(
            method::MUX_FILE_PUT_BEGIN,
            json!({"sessionId": session, "fileName": "big.bin", "size": size}),
        )
        .await;
    let id = begun["result"]["uploadId"].as_str().unwrap_or_else(|| panic!("{begun}")).to_owned();
    let put = json!({"sessionId": session, "uploadId": id, "offset": 0, "data": b64(&[7; 1024])});
    let put = c.call(method::MUX_FILE_PUT_CHUNK, put).await;
    assert_eq!(put["result"]["offset"], 1024, "{put}");
    let begun = c
        .call(method::MUX_FILE_PUT_BEGIN, json!({"sessionId": session, "fileName": "s", "size": 1}))
        .await;
    let small = begun["result"]["uploadId"].as_str().unwrap().to_owned();
    let past = json!({"sessionId": session, "uploadId": small, "offset": 0, "data": b64(b"ab")});
    let past = c.call(method::MUX_FILE_PUT_CHUNK, past).await;
    assert_eq!(past["error"]["data"]["reason"], "filePut.pastSize", "{past}");
    for upload in [id, small] {
        c.call(method::MUX_FILE_PUT_CANCEL, json!({"sessionId": session, "uploadId": upload}))
            .await;
    }
}

/// A prompt that waits behind a turn while its file is swept is refused when its turn comes: the
/// agent never gets a path to nothing.
#[tokio::test]
async fn a_waiting_prompt_whose_upload_was_swept_is_refused_at_its_turn() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-swept").await;
    let id = c.upload(&session, "gone.bin", b"\x00 any bytes").await;
    let link = json!({"type": "resource_link", "uri": format!("acpmux-upload:{id}"),
        "name": "gone.bin",
        "_meta": {"acpmux": {"upload": {"uploadId": id, "fileName": "gone.bin"}}}});
    c.post(method::SESSION_PROMPT, prompt(&session, "busy", "until-cancel", vec![])).await;
    c.until(|v| v.pointer("/params/update/content/text").is_some()).await;
    let asked = c.post(method::SESSION_PROMPT, prompt(&session, &v7(), "read", vec![link])).await;
    c.until(|v| v["method"] == "_acpmux/prompt_accepted" && v["params"]["queued"] == true).await;
    std::fs::remove_dir_all(home().join("uploads").join(&session).join(&id)).unwrap();
    c.post(method::SESSION_CANCEL, json!({"sessionId": session})).await;
    let reply = c.until(|v| v.get("id") == Some(&json!(asked))).await;
    assert_eq!(reply["error"]["data"]["reason"], "upload.missing", "{reply}");
    assert!(!c.text.contains("resource_link:gone.bin"), "{}", c.text);
}

/// An upload whose use cannot be marked (its `.used` marker cannot be written, as on a full disk)
/// is refused: the sweep would not know a turn needs it.
#[tokio::test]
async fn an_upload_whose_use_cannot_be_marked_is_refused() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-unmarked").await;
    let id = c.upload(&session, "data.bin", b"\x00 bytes").await;
    // A folder where the marker goes: writing it fails, as it would on a full disk.
    std::fs::create_dir(home().join("uploads").join(&session).join(&id).join(".used")).unwrap();
    let link = json!({"type": "resource_link", "uri": format!("acpmux-upload:{id}"),
        "name": "data.bin",
        "_meta": {"acpmux": {"upload": {"uploadId": id, "fileName": "data.bin"}}}});
    let reply = c.call(method::SESSION_PROMPT, prompt(&session, &v7(), "read", vec![link])).await;
    assert_eq!(reply["error"]["data"]["reason"], "upload.unreadable", "{reply}");
    assert!(c.user_messages(&session).await.is_empty());
}

/// An image too large for the model and a file of any other type go by path, never as base64.
#[tokio::test]
async fn a_large_image_and_any_other_file_go_by_path() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-path").await;
    let (big, data) = (png(6 << 20, 3), b"\x00\x01 not any known type".to_vec());
    let big_id = c.upload(&session, "big.png", &big).await;
    let data_id = c.upload(&session, "blob.bin", &data).await;
    let blob = json!({"type": "resource_link", "uri": format!("acpmux-upload:{data_id}"),
        "name": "blob.bin",
        "_meta": {"acpmux": {"upload": {"uploadId": data_id, "fileName": "blob.bin"}}}});
    let p = prompt(&session, &v7(), "see", vec![image_ref(&big_id, "big.png"), blob]);
    let reply = c.call(method::SESSION_PROMPT, p).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(!c.text.contains("image:"), "{}", c.text);
    let linked = links(&c.text);
    assert_eq!(linked.len(), 2, "{}", c.text);
    for ((name, path), bytes) in linked.iter().zip([&big, &data]) {
        assert_eq!(sha(&std::fs::read(path).unwrap()), sha(bytes), "{name}");
    }
    assert!(c.text.contains("resource_link:big.png:image/png:"), "{}", c.text);
    assert!(c.text.contains("resource_link:blob.bin:application/octet-stream:"), "{}", c.text);
}

/// Only a finished upload of the chat's own; never from a remote web client, and never in an edit
/// of a queued prompt. Nothing refused is recorded.
#[tokio::test]
async fn a_reference_outside_the_chats_finished_uploads_is_refused() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let (session, other) = (c.new_session("uploads-own").await, c.new_session("uploads-x").await);
    let theirs = c.upload(&other, "theirs.png", &png(64, 1)).await;
    let begun = json!({"sessionId": session, "fileName": "half.png", "size": 64});
    let half = c.call(method::MUX_FILE_PUT_BEGIN, begun).await;
    let half = half["result"]["uploadId"].as_str().unwrap().to_owned();
    let mine = c.upload(&session, "mine.png", &png(64, 2)).await;
    let cases = [
        (image_ref(&theirs, "theirs.png"), "upload.missing"),
        (image_ref(&half, "half.png"), "upload.missing"),
        (image_ref(&mine, "../mine.png"), "upload.missing"),
        (image_ref("not-an-id", "mine.png"), "upload.missing"),
        (
            json!({"type": "image", "_meta": {"acpmux": {"upload": {"uploadId": mine}}}}),
            "upload.invalid",
        ),
        (
            json!({"type": "resource_link", "uri": "acpmux-upload:other", "name": "mine.png",
                "_meta": {"acpmux": {"upload": {"uploadId": mine, "fileName": "mine.png"}}}}),
            "upload.invalid",
        ),
        (
            json!({"type": "resource", "resource": {"uri": "x"},
                "_meta": {"acpmux": {"upload": {"uploadId": mine, "fileName": "mine.png"}}}}),
            "upload.invalid",
        ),
        // The upload's uri with no reference: never handed to an agent unresolved.
        (
            json!({"type": "resource_link", "uri": format!("acpmux-upload:{mine}"),
                "name": "mine.png"}),
            "upload.invalid",
        ),
    ];
    for (block, reason) in cases {
        let reply = c.call(method::SESSION_PROMPT, prompt(&session, &v7(), "x", vec![block])).await;
        assert_eq!(reply["error"]["data"]["reason"], reason, "{reply}");
    }
    let mut web = client(&hub, Origin::Web);
    let p = prompt(&session, &v7(), "x", vec![image_ref(&mine, "mine.png")]);
    let reply = web.call(method::SESSION_PROMPT, p).await;
    // The remote guard refuses it first; the resolver would too (`upload.remote`, a unit test).
    let reason = reply["error"]["data"]["reason"].as_str().unwrap_or_default();
    assert!(reason.starts_with("remote.") || reason == "upload.remote", "{reply}");
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

/// A real `w`x`h` RGB PNG of noise, which no deflate shrinks: past the inline image size.
fn noise_png(w: u32, h: u32) -> Vec<u8> {
    let mut state = 0x2545_f491_4f6c_dd1du64;
    let data: Vec<u8> = (0..w * h * 3)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state as u8
        })
        .collect();
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, w, h);
    e.set_color(png::ColorType::Rgb);
    e.set_depth(png::BitDepth::Eight);
    e.set_compression(png::Compression::Fast);
    e.write_header().unwrap().write_image_data(&data).unwrap();
    out
}

/// A screenshot past what the model takes inline reaches the agent as the link to its original
/// and, next to it, a copy sized for the harness (`model_copies.rs`; this hub's harness is of the
/// codex family): long edge at most 2048 px, under the inline image size, saved next to the
/// upload. The transcript keeps the prompt as sent.
#[tokio::test]
async fn a_large_screenshot_reaches_the_model_as_a_sized_copy_next_to_its_original() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("uploads-model-copy").await;
    let big = noise_png(2400, 1200);
    assert!(big.len() > acpmux::prompt_uploads::INLINE_IMAGE_BYTES, "{}", big.len());
    let id = c.upload(&session, "shot.png", &big).await;
    let p = prompt(&session, &v7(), "see", vec![image_ref(&id, "shot.png")]);
    let reply = c.call(method::SESSION_PROMPT, p).await;
    assert!(reply.get("error").is_none(), "{reply}");
    // The original, by its path, bytes intact.
    let linked = links(&c.text);
    assert_eq!(linked.len(), 1, "{}", c.text);
    assert_eq!(sha(&std::fs::read(&linked[0].1).unwrap()), sha(&big));
    // The copy the agent got is the one saved next to the upload, sized for the model.
    let folder = linked[0].1.parent().unwrap().to_owned();
    let copies: Vec<_> = std::fs::read_dir(&folder)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with(".model-"))
        .collect();
    let sent: Vec<_> = copies
        .iter()
        .map(|p| std::fs::read(p).unwrap())
        .filter(|b| c.text.contains(&format!("image:{}", sha(b))))
        .collect();
    assert_eq!(sent.len(), 1, "copies {copies:?}: {}", c.text);
    let reader = png::Decoder::new(std::io::Cursor::new(&sent[0])).read_info().unwrap();
    let (w, h) = (reader.info().width, reader.info().height);
    assert!(w.max(h) <= 2048 && w == 2 * h, "{w}x{h}");
    assert!(sent[0].len() <= acpmux::prompt_uploads::INLINE_IMAGE_BYTES, "{}", sent[0].len());
    let messages = c.user_messages(&session).await;
    let logged = serde_json::to_string(&messages).unwrap();
    assert!(!logged.contains("scaled to"), "{logged}");
    // Nor any record of the log, what was written to the agent too: the copy's base64 is left out.
    let logged = whole_log(&mut c, &session).await;
    // The prompt as written to the agent is there, with the original's path.
    assert!(logged.contains(r#""dir":"out","kind":"session/prompt""#), "{logged:.2000}");
    let copy = b64(&sent[0]);
    assert!(!logged.contains(&copy[200..300]), "the copy's base64 was logged");
}

/// Claude Code echoes each prompt back (`--replay-user-messages`), the copy too: the log keeps
/// the copy neither as written to Claude nor as echoed.
#[tokio::test]
async fn a_screenshots_copy_is_logged_neither_written_to_claude_nor_echoed_back() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
        "_meta": {"acpmux": {"name": "uploads-claude-copy", "harness": "fakeclaude"}}});
    let made = c.call(method::SESSION_NEW, new).await;
    let session = made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}"));
    let session = session.to_owned();
    let big = noise_png(2400, 1200);
    let id = c.upload(&session, "shot.png", &big).await;
    let p = prompt(&session, &v7(), "see", vec![image_ref(&id, "shot.png")]);
    let reply = c.call(method::SESSION_PROMPT, p).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let logged = whole_log(&mut c, &session).await;
    // A copy went to Claude, and Claude echoed the prompt back.
    let folder = home().join("uploads").join(&session).join(&id);
    let copies: Vec<_> = std::fs::read_dir(&folder)
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with(".model-"))
        .collect();
    assert!(!copies.is_empty(), "no copy was made");
    assert!(logged.contains("model-sized copy, not logged"), "{logged:.3000}");
    assert!(logged.contains(r#""kind":"claude.user""#), "no echo: {logged:.3000}");
    for copy in copies {
        let data = b64(&std::fs::read(&copy).unwrap());
        assert!(!logged.contains(&data[200..300]), "{} was logged", copy.display());
    }
}
