//! Files sent with a message between sessions (`acpmux send --attach FILE`, `src/attach.rs`;
//! claude-sr2 scp'd Leo's screenshots to big-red one at a time on 2026-10-25). The receiving
//! daemon saves each owner-only in the session's uploads, an image reaches the agent and the
//! transcript as an image, a peer's session gets it over the link, and the caps, the names, a
//! retried delivery and a held one are checked.
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
    let hub = Hub::new(cfg, store);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

/// The person key these hubs hold, as a daemon the app started does.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// The app's connection: `initialize`, then the person proof (`hub/person.rs`).
async fn person(hub: &Arc<Hub>) -> Client {
    let mut c = client(hub, Origin::Local);
    let init = c.call("initialize", json!({"protocolVersion": 1})).await;
    let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    let proved = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
    assert_eq!(proved["result"]["person"], true, "{proved}");
    c
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

/// The one file `name` in session `session`'s uploads: its bytes, owner-only, in owner-only
/// folders.
fn assert_saved(session: &str, name: &str, bytes: &[u8]) -> PathBuf {
    let found: Vec<_> = saved(session).into_iter().filter(|p| p.ends_with(name)).collect();
    assert_eq!(found.len(), 1, "{name}: saved {:?}", saved(session));
    let path = home().join("uploads").join(session).join(&found[0]);
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
    let shot_path = assert_saved(&session, "shot.png", &shot);
    let notes_path = assert_saved(&session, "notes.txt", &notes);
    assert_saved(&session, "other.txt", &other);
    let fake_path = assert_saved(&session, "fake.png", b"not an image");
    for (name, path) in [("notes.txt", &notes_path), ("fake.png", &fake_path)] {
        let link =
            format!("resource_link:{name}:application/octet-stream:file://{}", path.display());
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
    assert_saved(&session, "escape.png", &png(32));
    assert_saved(&session, "win.txt", b"w");
    assert_saved(&session, "attachment", b"d");
    assert_saved(&session, "bashrc", b"b");
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
    assert_saved(&session, "max.png", &png(MAX_FILE));
}

/// The outbox's retry sends the same prompt id again with `resend`: one copy, one message, and a
/// resend with other bytes changes nothing the first run reads.
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
    let reply = c.call(method::SESSION_PROMPT, first.clone()).await;
    assert!(reply.get("error").is_none(), "{reply}");
    first["prompt"][1] = image("shot.png", &png(300));
    let reply = c.call(method::SESSION_PROMPT, first).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_saved(&session, "shot.png", &shot);
    assert_eq!(c.user_messages(&session).await.len(), 1);
    // The transcript keeps the first run's image, and no copy of the resend's.
    assert!(home().join("attachments").join(sha(&shot)).is_file());
    assert!(!home().join("attachments").join(sha(&png(300))).exists());
}

/// A message an agent pair holds keeps its files for the release; the sender's resend of it is
/// held again and keeps none (`hub/agent_pairs.rs`).
#[tokio::test]
async fn a_held_message_and_its_resend_keep_one_copy() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let (a, b) = (c.new_session("attach-pair-a").await, c.new_session("attach-pair-b").await);
    let (shot, mut reply) = (png(128), Value::Null);
    for (n, resend) in [(1, false), (2, false), (3, false), (3, true)] {
        let provenance = json!({"kind": "agent_message", "from": format!("acp:{a}"),
            "fromName": "agent", "to": format!("acp:{b}"), "msgId": format!("h{n}"),
            "threadId": "t-1"});
        let mux = json!({"promptId": format!("h{n}"), "provenance": provenance, "resend": resend});
        let blocks = json!([{"type": "text", "text": "please check the build"},
            image("shot.png", &shot)]);
        let p = json!({"sessionId": b, "prompt": blocks, "_meta": {"acpmux": mux}});
        reply = c.call(method::SESSION_PROMPT, p).await;
    }
    assert_eq!(reply["error"]["data"]["held"], true, "{reply}");
    assert_eq!(reply["error"]["data"]["resent"], true, "{reply}");
    let shots: Vec<_> = saved(&b).into_iter().filter(|p| p.ends_with("shot.png")).collect();
    assert_eq!(shots.len(), 3, "h1, h2 and the held h3, not its resend: {shots:?}");
}

/// A message queued behind a running turn keeps its files while it waits and when it runs; one
/// taken out of the queue unrun (`_acpmux/queue_remove`; superseding settles the same way) keeps
/// none.
#[tokio::test]
async fn a_queued_message_withdrawn_before_it_runs_keeps_none() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let mut q = client(&hub, Origin::Local);
    let session = c.new_session("attach-queued").await;
    let (gone, kept) = (png(96), png(97));
    let prompt = |id: &str, text: &str, files: Vec<Value>| {
        let mut blocks = vec![json!({"type": "text", "text": text})];
        blocks.extend(files);
        let p =
            json!({"sessionId": session, "prompt": blocks, "_meta": {"acpmux": {"promptId": id}}});
        Message::request(json!(id), method::SESSION_PROMPT, p).to_line()
    };
    c.0.send(prompt("busy", "until-cancel", vec![])).await.unwrap();
    c.0.send(prompt("gone", "never", vec![image("gone.png", &gone)])).await.unwrap();
    c.0.send(prompt("kept", "later", vec![image("kept.png", &kept)])).await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let page =
            q.call("_acpmux/events", json!({"sessionId": session, "kinds": ["queued"]})).await;
        if page["result"]["events"].as_array().is_some_and(|e| e.len() == 2) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "never queued: {page}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(saved(&session).len(), 2, "{:?}", saved(&session));
    let removed =
        q.call(method::MUX_QUEUE_REMOVE, json!({"sessionId": session, "promptId": "gone"})).await;
    assert_eq!(removed["result"]["removed"], true, "{removed}");
    q.call(method::SESSION_CANCEL, json!({"sessionId": session})).await;
    let mut answered = std::collections::HashMap::new();
    while answered.len() < 3 {
        let line =
            tokio::time::timeout(Duration::from_secs(30), c.1.recv()).await.unwrap().unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if let Some(id) = v.get("id").and_then(Value::as_str) {
            answered.insert(id.to_owned(), v);
        }
    }
    assert_eq!(answered["gone"].pointer("/result/_meta/acpmux/withdrawn"), Some(&json!(true)));
    assert!(answered["kept"].get("error").is_none(), "{}", answered["kept"]);
    assert_saved(&session, "kept.png", &kept);
    assert_eq!(saved(&session).len(), 1, "{:?}", saved(&session));
}

/// Files come with a message, never with an edit of a queued one (`_acpmux/queue_edit`).
#[tokio::test]
async fn a_queue_edit_cannot_attach_files() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-edit").await;
    let edit = json!({"sessionId": session, "promptId": "p", "op": "update",
        "prompt": [{"type": "text", "text": "x"}, image("shot.png", &png(64))]});
    let reply = c.call(method::MUX_QUEUE_EDIT, edit).await;
    assert_eq!(reply["error"]["data"]["reason"], "attach.edit", "{reply}");
}

/// A held message the person releases into a busy session waits in its queue; withdrawn there
/// before it runs, it keeps no files.
#[tokio::test]
async fn a_released_held_message_withdrawn_before_it_runs_keeps_none() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let (a, b) = (c.new_session("attach-rel-a").await, c.new_session("attach-rel-b").await);
    let shot = png(144);
    let mut reply = Value::Null;
    for n in 1..=3 {
        let provenance = json!({"kind": "agent_message", "from": format!("acp:{a}"),
            "fromName": "agent", "to": format!("acp:{b}"), "msgId": format!("r{n}"),
            "threadId": "t-1"});
        let mux = json!({"promptId": format!("r{n}"), "provenance": provenance});
        let blocks = json!([{"type": "text", "text": "please check the build"},
            image("shot.png", &shot)]);
        let p = json!({"sessionId": b, "prompt": blocks, "_meta": {"acpmux": mux}});
        reply = c.call(method::SESSION_PROMPT, p).await;
    }
    assert_eq!(reply["error"]["data"]["held"], true, "{reply}");
    let busy = json!({"sessionId": b, "prompt": [{"type": "text", "text": "until-cancel"}]});
    c.0.send(Message::request(json!("busy"), method::SESSION_PROMPT, busy).to_line())
        .await
        .unwrap();
    let mut q = client(&hub, Origin::Local);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while q.user_messages(&b).await.len() < 3 {
        assert!(tokio::time::Instant::now() < deadline, "the busy turn never started");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    person(&hub).await.call("_acpmux/agent_pair_resume", json!({"sessionId": a})).await;
    loop {
        let page = q.call("_acpmux/events", json!({"sessionId": b, "kinds": ["queued"]})).await;
        if page["result"]["events"].as_array().is_some_and(|e| !e.is_empty()) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "the release never queued: {page}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let removed = q.call(method::MUX_QUEUE_REMOVE, json!({"sessionId": b, "promptId": "r3"})).await;
    assert_eq!(removed["result"]["removed"], true, "{removed}");
    q.call(method::SESSION_CANCEL, json!({"sessionId": b})).await;
    let shots = || saved(&b).into_iter().filter(|p| p.ends_with("shot.png")).count();
    while shots() != 2 {
        assert!(tokio::time::Instant::now() < deadline, "r3 kept its files: {:?}", saved(&b));
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A message refused by a check after its files were read (here its `fromAgent`) keeps none.
#[tokio::test]
async fn a_message_refused_after_its_files_are_read_keeps_none() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-refused").await;
    let p = json!({"sessionId": session, "prompt": [{"type": "text", "text": "x"},
        image("shot.png", &png(64))], "_meta": {"acpmux": {"promptId": v7(), "fromAgent": 7}}});
    let reply = c.call(method::SESSION_PROMPT, p).await;
    assert!(reply.get("error").is_some(), "{reply}");
    assert!(saved(&session).is_empty(), "{:?}", saved(&session));
}

/// `acpmux send --no-wait` (`_acpmux/send_queue`) past the cap is refused before the outbox keeps
/// it, and within it the attachment reaches the session.
#[tokio::test]
async fn a_queued_send_over_the_cap_is_refused_before_the_outbox_keeps_it() {
    let hub = hub();
    let mut c = client(&hub, Origin::Local);
    let session = c.new_session("attach-queue").await;
    let request = json!({"sessionId": session, "prompt": [image("big.png", &png(MAX_FILE + 1))]});
    let queued = c.call("_acpmux/send_queue", json!({"request": request})).await;
    assert_eq!(queued["error"]["data"]["reason"], "attach.tooLarge", "{queued}");
    let shot = png(128);
    let request = json!({"sessionId": session, "prompt": [{"type": "text", "text": "q"},
        image("q.png", &shot)]});
    let queued = c.call("_acpmux/send_queue", json!({"request": request})).await;
    let id = queued["result"]["deliveryId"].as_str().unwrap_or_else(|| panic!("{queued}"));
    let status = json!({"deliveryId": id, "waitMs": 10000});
    let settled = c.call("_acpmux/send_status", status).await;
    assert_eq!(settled["result"]["status"], "delivered", "{settled}");
    assert_saved(&session, "q.png", &shot);
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
    assert_saved(&remote, "leo.png", &shot);
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

/// A peer on a build from before attachments would run the message without saving its files:
/// refused before anything is sent, naming the update. A peer that lists one session, `old-1`,
/// and no `sendAttach` feature, counting the prompts it gets.
#[tokio::test]
async fn a_peer_that_does_not_save_attachments_is_refused_before_anything_is_sent() {
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
                            "build": "older", "origin": "peer", "features": ["trustGate"]}}}),
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
    let (reply, _) = ca.send("old-1", &v7(), "see", vec![image("a.png", &png(32))]).await;
    assert_eq!(reply["error"]["data"]["reason"], "attach.unsupported", "{reply}");
    assert!(reply["error"]["message"].as_str().unwrap().contains("acpmux host update old"));
    assert_eq!(prompts.load(Ordering::SeqCst), 0);
    // A message with no attachment still goes.
    let (reply, _) = ca.send("old-1", &v7(), "plain", vec![]).await;
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(prompts.load(Ordering::SeqCst), 1);
}
