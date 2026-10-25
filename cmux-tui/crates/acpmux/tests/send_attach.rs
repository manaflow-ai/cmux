//! Files sent with a message between sessions (`acpmux send --attach FILE`, `src/attach.rs`;
//! claude-sr2 scp'd Leo's screenshots to big-red one at a time on 2026-10-25). The receiving
//! daemon saves each owner-only in the session's uploads, an image reaches the agent and the
//! transcript as an image, a peer's session gets it over the link, and the caps, the names and a
//! retried delivery are checked.
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
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The caps `src/attach.rs` states: 8 MiB a file, 10 MiB a message.
const MAX_FILE: usize = 8 << 20;
const MAX_MESSAGE: usize = 10 << 20;

fn home() -> &'static Path {
    static HOME: OnceLock<PathBuf> = OnceLock::new();
    HOME.get_or_init(|| {
        let home = std::env::temp_dir().join(format!("acpmux-send-attach-{}", std::process::id()));
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
    /// The reply to `m`, and the agent text streamed before it.
    async fn call_text(&mut self, m: &str, params: Value) -> (Value, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return (value, text);
            }
            if let Some(chunk) =
                value.pointer("/params/update/content/text").and_then(Value::as_str)
            {
                text.push_str(chunk);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.call_text(m, params).await.0
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

    /// `session/prompt` of `text` and `attachments`, under prompt id `id`.
    async fn send(&mut self, to: &str, id: &str, text: &str, files: Vec<Value>) -> (Value, String) {
        let mut blocks = vec![json!({"type": "text", "text": text})];
        blocks.extend(files);
        let p = json!({"sessionId": to, "prompt": blocks, "_meta": {"acpmux": {"promptId": id}}});
        self.call_text(method::SESSION_PROMPT, p).await
    }

    async fn user_messages(&mut self, session: &str) -> Vec<Value> {
        let page = self
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}))
            .await;
        let events = page["result"]["events"].as_array().unwrap_or_else(|| panic!("{page}"));
        events.iter().map(|e| e["msg"].clone()).collect()
    }
}

/// A PNG's bytes (its signature is what the type is read from), `n` long.
fn png(n: usize) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    bytes.resize(n.max(bytes.len()), 7);
    bytes
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn sha(bytes: &[u8]) -> String {
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// An image attachment as `acpmux send --attach` sends it.
fn image(name: &str, bytes: &[u8]) -> Value {
    json!({"type": "image", "mimeType": "image/png", "data": b64(bytes), "name": name,
           "_meta": {"acpmux": {"attachment": {"name": name}}}})
}

/// Any other file: an embedded resource with its bytes as `blob`.
fn resource(name: &str, bytes: &[u8]) -> Value {
    json!({"type": "resource",
           "resource": {"uri": format!("attachment://{name}"), "mimeType": "text/plain", "blob": b64(bytes)},
           "_meta": {"acpmux": {"attachment": {"name": name}}}})
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// Every file under session `session`'s uploads (`<prompt id>/<name>`).
fn saved(session: &str) -> Vec<PathBuf> {
    let root = home().join("uploads").join(session);
    let entries = |dir: &Path| std::fs::read_dir(dir).into_iter().flatten().flatten();
    let mut out: Vec<PathBuf> = entries(&root)
        .flat_map(|folder| entries(&folder.path()).collect::<Vec<_>>())
        .map(|file| file.path().strip_prefix(&root).unwrap().to_owned())
        .collect();
    out.sort();
    out
}

/// The file `name` of prompt `id` in session `session`'s uploads: its bytes, owner-only, in
/// owner-only folders.
fn assert_saved(session: &str, id: &str, name: &str, bytes: &[u8]) -> PathBuf {
    let path = home().join("uploads").join(session).join(id).join(name);
    assert!(path.is_file(), "{} not saved; saved: {:?}", path.display(), saved(session));
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    assert_eq!(mode(&path), 0o600, "{}", path.display());
    assert_eq!(mode(path.parent().unwrap()), 0o700);
    assert_eq!(mode(path.parent().unwrap().parent().unwrap()), 0o700);
    path
}

fn v7() -> String {
    uuid::Uuid::now_v7().to_string()
}

/// The agent gets the image as an image block and a text file as a link to its saved copy; the
/// type is read from the bytes, not the label (a PNG sent as a `.txt` resource is an image, text
/// labelled `image/png` is not); the transcript names the image and hands it back.
#[tokio::test]
async fn a_local_send_with_attachments_reaches_the_agent_and_the_transcript_and_is_saved_owner_only()
 {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-local").await;
    let (shot, other, notes) = (png(4096), png(64), b"line one\n".to_vec());
    let id = v7();
    let files = vec![
        image("shot.png", &shot),
        resource("notes.txt", &notes),
        resource("other.txt", &other),
        image("fake.png", b"not an image"),
    ];
    let (reply, echoed) = c.send(&session, &id, "look", files).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(echoed.contains(&format!("image:{}", sha(&shot))), "{echoed}");
    assert!(echoed.contains(&format!("image:{}", sha(&other))), "{echoed}");
    assert!(!echoed.contains(&format!("image:{}", sha(b"not an image"))), "{echoed}");
    let shot_path = assert_saved(&session, &id, "shot.png", &shot);
    let notes_path = assert_saved(&session, &id, "notes.txt", &notes);
    assert_saved(&session, &id, "other.txt", &other);
    let fake_path = assert_saved(&session, &id, "fake.png", b"not an image");
    for (name, path) in [("notes.txt", &notes_path), ("fake.png", &fake_path)] {
        let link = format!("resource_link:{name}:application/octet-stream:file://{}", path.display());
        assert!(echoed.contains(&link), "{echoed}");
    }
    // The agent is told where they are, and never gets a file's bytes as text.
    assert!(echoed.contains(&shot_path.display().to_string()), "{echoed}");
    assert!(!echoed.contains(&b64(&notes)), "{echoed}");

    let messages = c.user_messages(&session).await;
    assert_eq!(messages.len(), 1, "{messages:?}");
    let message = &messages[0];
    assert_eq!(message["text"], "look", "the transcript shows the person's words only: {message}");
    assert_eq!(message["images"][0]["id"], sha(&shot), "{message}");
    assert_eq!(message["images"][0]["mimeType"], "image/png", "{message}");
    let parts = message["inlineParts"].as_array().unwrap_or_else(|| panic!("{message}"));
    let kinds: Vec<_> = parts.iter().filter_map(|p| p["kind"].as_str()).collect();
    assert_eq!(kinds, ["text", "image", "file", "image", "file"], "{message}");
    let read = c.call("_acpmux/attachment", json!({"sessionId": session, "id": sha(&shot)})).await;
    assert_eq!(read["result"]["data"], b64(&shot), "{read}");
    // The transcript's own copy is owner-only too.
    assert_eq!(mode(&home().join("attachments").join(sha(&shot))), 0o600);
}

/// A name from the sender never leaves the session's folder: its last component, made plain.
#[tokio::test]
async fn a_traversal_name_is_sanitized_into_the_sessions_folder() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-names").await;
    let id = v7();
    let files = vec![
        image("../../../../escape.png", &png(32)),
        resource("..\\..\\win.txt", b"w"),
        resource("..", b"d"),
        resource(".bashrc", b"b"),
    ];
    let (reply, _) = c.send(&session, &id, "names", files).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_saved(&session, &id, "escape.png", &png(32));
    assert_saved(&session, &id, "win.txt", b"w");
    assert_saved(&session, &id, "attachment", b"d");
    assert_saved(&session, &id, "bashrc", b"b");
    assert_eq!(saved(&session).len(), 4, "{:?}", saved(&session));
    assert!(!home().join("escape.png").exists() && !home().join("uploads/escape.png").exists());
}

/// Over a cap the message is refused with the cap in its words, and nothing is saved or run; at
/// the cap it goes. A remote web connection writes no file here (as `_acpmux/file_put`).
#[tokio::test]
async fn an_attachment_over_the_cap_is_refused_and_nothing_is_saved() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-cap").await;
    let (big, _) = c.send(&session, &v7(), "big", vec![image("big.png", &png(MAX_FILE + 1))]).await;
    assert_eq!(big["error"]["data"]["reason"], "attach.tooLarge", "{big}");
    assert!(big["error"]["message"].as_str().unwrap().contains("8 MiB"), "{big}");
    let half = png(MAX_MESSAGE / 2 + 1);
    let (two, _) =
        c.send(&session, &v7(), "two", vec![image("a.png", &half), image("b.png", &half)]).await;
    assert_eq!(two["error"]["data"]["reason"], "attach.tooLarge", "{two}");
    assert!(two["error"]["message"].as_str().unwrap().contains("10 MiB"), "{two}");
    let mut web = client(&hub, Origin::Web);
    let (from_web, _) = web.send(&session, &v7(), "web", vec![image("w.png", &png(32))]).await;
    assert!(from_web.get("error").is_some(), "{from_web}");
    assert!(saved(&session).is_empty(), "{:?}", saved(&session));
    assert!(c.user_messages(&session).await.is_empty());
    let id = v7();
    let (ok, _) = c.send(&session, &id, "fits", vec![image("max.png", &png(MAX_FILE))]).await;
    assert!(ok.get("error").is_none(), "{ok}");
    assert_saved(&session, &id, "max.png", &png(MAX_FILE));
}

/// The outbox's retry sends the same prompt id again with `resend`: one copy, one message.
#[tokio::test]
async fn a_retried_delivery_stores_one_copy() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-retry").await;
    let (shot, id) = (png(256), v7());
    let mut first = json!({"sessionId": session, "prompt": [{"type": "text", "text": "once"},
        image("shot.png", &shot)], "_meta": {"acpmux": {"promptId": id}}});
    let reply = c.call(method::SESSION_PROMPT, first.clone()).await;
    assert!(reply.get("error").is_none(), "{reply}");
    first["_meta"]["acpmux"]["resend"] = json!(true);
    let reply = c.call(method::SESSION_PROMPT, first).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(saved(&session), [PathBuf::from(&id).join("shot.png")]);
    assert_eq!(c.user_messages(&session).await.len(), 1);
}

/// A session on another host gets the file over the peer link, no scp: saved owner-only on the
/// host that runs it, an image for its agent, the sender's chip in its transcript, readable
/// through the sender's daemon. Over the cap is refused before the link.
#[tokio::test]
async fn a_send_to_a_peers_session_lands_the_attachment_on_the_peer() {
    // B (big-red) runs the lane; A, the sender's daemon, mirrors B as a peer.
    let b = hub();
    let dir = std::env::temp_dir().join(format!("send-attach-peer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let auth = PeerAuth::create(&dir).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = client(&b, Origin::Local);
    let remote = cb.new_session("attach-far").await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    let (shot, id) = (png(64 << 10), v7());
    let mut sent = json!({"sessionId": "b/attach-far", "prompt": [{"type": "text", "text": "see"},
        image("leo.png", &shot)], "_meta": {"acpmux": {"promptId": id, "fromAgent": "claude-sr2"}}});
    let (reply, echoed) = ca.call_text(method::SESSION_PROMPT, sent.take()).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["peer"], "b", "{reply}");
    assert!(echoed.contains(&format!("image:{}", sha(&shot))), "{echoed}");
    assert_saved(&remote, &id, "leo.png", &shot);
    let messages = cb.user_messages(&remote).await;
    assert_eq!(messages.len(), 1, "{messages:?}");
    assert_eq!(messages[0]["images"][0]["id"], sha(&shot), "{messages:?}");
    assert_eq!(messages[0]["_meta"]["provenance"]["fromName"], "claude-sr2", "{messages:?}");
    let read =
        ca.call("_acpmux/attachment", json!({"sessionId": "b/attach-far", "id": sha(&shot)})).await;
    assert_eq!(read["result"]["data"], b64(&shot), "{read}");

    let big = vec![image("big.png", &png(MAX_FILE + 1))];
    let (big, _) = ca.send("b/attach-far", &v7(), "big", big).await;
    assert_eq!(big["error"]["data"]["reason"], "attach.tooLarge", "{big}");
    assert_eq!(saved(&remote).len(), 1, "{:?}", saved(&remote));
    assert_eq!(a.peers()[0]["connected"], true, "{:?}", a.peers());
}
