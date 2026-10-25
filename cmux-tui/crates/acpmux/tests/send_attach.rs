//! Files sent with a message between sessions (`acpmux send --attach FILE`, `src/attach.rs`).
//! claude-sr2 spent minutes on 2026-10-25 copying Leo's screenshots to big-red one at a time
//! with scp so lanes there could see them; Leo: "If this doesn't work as well as it should, we
//! need to improve ACP Mux." A file now rides in the message: the receiving daemon saves it
//! owner-only in the session's uploads folder, an image reaches the agent and the transcript
//! as an image, a session on another host gets it over the peer link, and the caps, the file
//! name and a retried delivery are checked here.

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

    async fn user_messages(&mut self, session: &str) -> Vec<Value> {
        let page = self
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]}))
            .await;
        page["result"]["events"]
            .as_array()
            .unwrap_or_else(|| panic!("{page}"))
            .iter()
            .map(|e| e["msg"].clone())
            .collect()
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

/// An attachment block as `acpmux send --attach` sends it: an image, its name in the mark.
fn image_attachment(name: &str, bytes: &[u8]) -> Value {
    json!({"type": "image", "mimeType": "image/png", "data": b64(bytes), "name": name,
           "_meta": {"acpmux": {"attachment": {"name": name}}}})
}

/// Any other file: an embedded resource with its bytes as `blob`.
fn resource_attachment(name: &str, mime: &str, bytes: &[u8]) -> Value {
    json!({"type": "resource",
           "resource": {"uri": format!("attachment://{name}"), "mimeType": mime, "blob": b64(bytes)},
           "_meta": {"acpmux": {"attachment": {"name": name}}}})
}

fn prompt(session: &str, prompt_id: &str, text: &str, attachments: Vec<Value>) -> Value {
    let mut blocks = vec![json!({"type": "text", "text": text})];
    blocks.extend(attachments);
    json!({"sessionId": session, "prompt": blocks, "_meta": {"acpmux": {"promptId": prompt_id}}})
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// Every file under session `session`'s uploads, relative to that folder.
fn saved(session: &str) -> Vec<PathBuf> {
    let root = home().join("uploads").join(session);
    let mut out = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                out.push(path.strip_prefix(&root).unwrap().to_owned());
            }
        }
    }
    out.sort();
    out
}

/// The file `name` of prompt `prompt_id` in session `session`'s uploads: its bytes, owner-only,
/// in owner-only folders.
fn assert_saved(session: &str, prompt_id: &str, name: &str, bytes: &[u8]) -> PathBuf {
    let path = home().join("uploads").join(session).join(prompt_id).join(name);
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

/// A send with an image and a text file: the agent gets the image as an image block and the text
/// file as a link to the saved copy, both saved owner-only in the session's uploads; the
/// transcript names the image, and `_acpmux/attachment` hands it back.
#[tokio::test]
async fn a_local_send_with_attachments_reaches_the_agent_and_the_transcript_and_is_saved_owner_only()
 {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-local").await;
    let shot = png(4096);
    let notes = b"line one\nline two\n".to_vec();
    let id = v7();
    let (reply, echoed) = c
        .call_text(
            method::SESSION_PROMPT,
            prompt(
                &session,
                &id,
                "look",
                vec![
                    image_attachment("shot.png", &shot),
                    resource_attachment("notes.txt", "text/plain", &notes),
                ],
            ),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(echoed.contains(&format!("image:{}", sha(&shot))), "{echoed}");
    let png_path = assert_saved(&session, &id, "shot.png", &shot);
    let notes_path = assert_saved(&session, &id, "notes.txt", &notes);
    // The text file reaches the agent as a link to its saved copy, and the agent is told where
    // both are.
    let link = format!("resource_link:notes.txt:application/octet-stream:file://{}", notes_path.display());
    assert!(echoed.contains(&link), "{echoed}");
    assert!(echoed.contains(&png_path.display().to_string()), "{echoed}");
    assert!(!echoed.contains(&b64(&notes)), "the file's bytes reached the agent as text: {echoed}");

    let messages = c.user_messages(&session).await;
    assert_eq!(messages.len(), 1, "{messages:?}");
    let message = &messages[0];
    assert_eq!(message["text"], "look", "the transcript shows the person's words only: {message}");
    assert_eq!(message["images"][0]["id"], sha(&shot), "{message}");
    assert_eq!(message["images"][0]["mimeType"], "image/png", "{message}");
    let kinds: Vec<&str> = message["inlineParts"]
        .as_array()
        .unwrap_or_else(|| panic!("{message}"))
        .iter()
        .filter_map(|p| p["kind"].as_str())
        .collect();
    assert_eq!(kinds, ["text", "image", "file"], "{message}");
    let read = c.call("_acpmux/attachment", json!({"sessionId": session, "id": sha(&shot)})).await;
    assert_eq!(read["result"]["data"], b64(&shot), "{read}");
    // The transcript's own copy is owner-only too.
    assert_eq!(mode(&home().join("attachments").join(sha(&shot))), 0o600);
}

/// The type comes from the bytes, not from what the sender says: text labelled `image/png` is not
/// an image, and a PNG named `.txt` is one.
#[tokio::test]
async fn an_attachments_type_is_read_from_its_bytes() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-sniff").await;
    let shot = png(64);
    let id = v7();
    let mut lying = image_attachment("fake.png", b"not an image");
    lying["mimeType"] = json!("image/png");
    let (reply, echoed) = c
        .call_text(
            method::SESSION_PROMPT,
            prompt(
                &session,
                &id,
                "types",
                vec![lying, resource_attachment("shot.txt", "text/plain", &shot)],
            ),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert!(echoed.contains(&format!("image:{}", sha(&shot))), "{echoed}");
    assert!(echoed.contains("resource_link:fake.png:application/octet-stream:file://"), "{echoed}");
    assert!(!echoed.contains(&format!("image:{}", sha(b"not an image"))), "{echoed}");
    assert_saved(&session, &id, "fake.png", b"not an image");
    assert_saved(&session, &id, "shot.txt", &shot);
}

/// A name from the sender never leaves the session's folder: its last component, made plain.
#[tokio::test]
async fn a_traversal_name_is_sanitized_into_the_sessions_folder() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-names").await;
    let id = v7();
    let (reply, _) = c
        .call_text(
            method::SESSION_PROMPT,
            prompt(
                &session,
                &id,
                "names",
                vec![
                    image_attachment("../../../../escape.png", &png(32)),
                    resource_attachment("..\\..\\win.txt", "text/plain", b"w"),
                    resource_attachment("..", "text/plain", b"d"),
                    resource_attachment(".bashrc", "text/plain", b"b"),
                ],
            ),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_saved(&session, &id, "escape.png", &png(32));
    assert_saved(&session, &id, "win.txt", b"w");
    assert_saved(&session, &id, "attachment", b"d");
    assert_saved(&session, &id, "bashrc", b"b");
    assert_eq!(saved(&session).len(), 4, "{:?}", saved(&session));
    assert!(!home().join("escape.png").exists() && !home().join("uploads/escape.png").exists());
}

/// Over a cap the message is refused with the cap in its words, and nothing is saved or run.
#[tokio::test]
async fn an_attachment_over_the_cap_is_refused_and_nothing_is_saved() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-cap").await;
    let big = c
        .call(
            method::SESSION_PROMPT,
            prompt(&session, &v7(), "big", vec![image_attachment("big.png", &png(MAX_FILE + 1))]),
        )
        .await;
    assert_eq!(big["error"]["data"]["reason"], "attach.tooLarge", "{big}");
    assert!(big["error"]["message"].as_str().unwrap().contains("8 MiB"), "{big}");
    let half = MAX_MESSAGE / 2 + 1;
    let two = c
        .call(
            method::SESSION_PROMPT,
            prompt(
                &session,
                &v7(),
                "two",
                vec![image_attachment("a.png", &png(half)), image_attachment("b.png", &png(half))],
            ),
        )
        .await;
    assert_eq!(two["error"]["data"]["reason"], "attach.tooLarge", "{two}");
    assert!(two["error"]["message"].as_str().unwrap().contains("10 MiB"), "{two}");
    assert!(saved(&session).is_empty(), "{:?}", saved(&session));
    assert!(c.user_messages(&session).await.is_empty());
    // At the caps exactly, it goes.
    let id = v7();
    let ok = c
        .call(
            method::SESSION_PROMPT,
            prompt(&session, &id, "fits", vec![image_attachment("max.png", &png(MAX_FILE))]),
        )
        .await;
    assert!(ok.get("error").is_none(), "{ok}");
    assert_saved(&session, &id, "max.png", &png(MAX_FILE));
}

/// A remote web connection writes no file on this machine (as `_acpmux/file_put`).
#[tokio::test]
async fn a_web_connection_may_not_attach_files() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-web").await;
    let mut web = client(&hub, Origin::Web);
    let reply = web
        .call(
            method::SESSION_PROMPT,
            prompt(&session, &v7(), "web", vec![image_attachment("w.png", &png(32))]),
        )
        .await;
    assert!(reply.get("error").is_some(), "{reply}");
    assert!(saved(&session).is_empty(), "{:?}", saved(&session));
}

/// The outbox's retry sends the same prompt id again with `resend`: the session keeps one copy of
/// each file and one message.
#[tokio::test]
async fn a_retried_delivery_stores_one_copy() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-retry").await;
    let shot = png(256);
    let id = v7();
    let first = prompt(&session, &id, "once", vec![image_attachment("shot.png", &shot)]);
    let reply = c.call(method::SESSION_PROMPT, first.clone()).await;
    assert!(reply.get("error").is_none(), "{reply}");
    let mut again = first;
    again["_meta"]["acpmux"]["resend"] = json!(true);
    let reply = c.call(method::SESSION_PROMPT, again).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(saved(&session), [PathBuf::from(&id).join("shot.png")]);
    assert_eq!(c.user_messages(&session).await.len(), 1);
}

/// B's WebSocket listener with a peer token; returns its port and the token.
async fn listen_with_peer_token(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let dir = std::env::temp_dir().join(format!("send-attach-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let auth = PeerAuth::create(&dir).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

/// A session on another host gets the file over the peer link, no scp: saved owner-only on the
/// host that runs it, an image block for its agent, the sender's chip in its transcript, and the
/// image readable through the sender's daemon. Over the cap is refused before the link.
#[tokio::test]
async fn a_send_to_a_peers_session_lands_the_attachment_on_the_peer() {
    // B (big-red) runs the lane; A, the sender's daemon, mirrors B as a peer.
    let b = hub();
    let (port, peer_token) = listen_with_peer_token(b.clone(), "peer").await;
    let mut cb = client(&b, Origin::Local);
    let remote = cb.new_session("attach-far").await;
    let a = hub();
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(peer_token), true)
        .await
        .unwrap();
    let mut ca = client(&a, Origin::Local);
    let shot = png(64 << 10);
    let id = v7();
    let mut sent = prompt("b/attach-far", &id, "see this", vec![image_attachment("leo.png", &shot)]);
    sent["_meta"]["acpmux"]["fromAgent"] = json!("claude-sr2");
    let (reply, echoed) = ca.call_text(method::SESSION_PROMPT, sent).await;
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

    // Past the cap: refused, nothing more saved on B, and the link stays up.
    let big = ca
        .call(
            method::SESSION_PROMPT,
            prompt("b/attach-far", &v7(), "big", vec![image_attachment("big.png", &png(MAX_FILE + 1))]),
        )
        .await;
    assert_eq!(big["error"]["data"]["reason"], "attach.tooLarge", "{big}");
    assert_eq!(saved(&remote).len(), 1, "{:?}", saved(&remote));
    assert_eq!(a.peers()[0]["connected"], true, "{:?}", a.peers());
}
