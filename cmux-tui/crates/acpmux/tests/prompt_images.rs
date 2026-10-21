//! Images sent with a prompt stay with the chat (Leo, 2026-10-13: a sent prompt's images
//! vanished). The prompt's `user_message` names each image by its content hash, the bytes are
//! kept once under `<ACPMUX_HOME>/attachments`, and `_acpmux/attachment` hands an image back to
//! whoever can read the session, also after a restart. An id the session never sent reads nothing.
//!
//! A queued prompt keeps its images too (Leo, 2026-10-21: his queued row showed text only, and
//! editing the queued text dropped the screenshot): the queue lists them, they read back before
//! the prompt runs, and an edit of its text keeps them (or only the ones it names).

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// A 1×1 PNG.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

fn hub(dir: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        self.reply(id).await
    }

    /// Sends a request without waiting for its answer (`reply`).
    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        id
    }

    async fn reply(&mut self, id: i64) -> Value {
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
}

/// The root every test here shares: the home (and its `attachments`) is the process's, set once;
/// each test has its own store under it.
fn root() -> &'static Path {
    static ROOT: OnceLock<PathBuf> = OnceLock::new();
    ROOT.get_or_init(|| {
        let root =
            std::env::temp_dir().join(format!("acpmux-prompt-images-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        acpmux::config::set_home_override(root.join("home"));
        root
    })
}

fn store(name: &str) -> PathBuf {
    let store = root().join(name);
    std::fs::create_dir_all(&store).unwrap();
    store
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The `user_message` records of `session`, oldest first.
async fn user_messages(c: &mut Client, session: &str) -> Vec<Value> {
    let reply =
        c.call("_acpmux/events", json!({"sessionId": session, "kinds": ["user_message"]})).await;
    reply["result"]["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
}

#[tokio::test]
async fn a_prompts_images_are_named_in_its_message_and_read_back_after_a_restart() {
    let store = store("restart");
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD.decode(PNG).unwrap();
    let id = sha256_hex(&bytes);

    let first = hub(&store);
    let mut c = client(&first);
    let session = c
        .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}))
        .await["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let reply = c
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [
                {"type": "text", "text": "what is this"},
                {"type": "image", "mimeType": "image/png", "data": PNG, "name": "shot.png"}
            ]}),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");

    let sent = user_messages(&mut c, &session).await;
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["text"], "what is this");
    assert_eq!(sent[0]["images"], json!([{"id": id, "mimeType": "image/png", "name": "shot.png"}]));
    // The log names the image; its bytes are kept apart, once.
    assert!(!sent[0].to_string().contains(PNG));

    let read = c.call("_acpmux/attachment", json!({"sessionId": session, "id": id})).await;
    assert_eq!(read["result"], json!({"mimeType": "image/png", "data": PNG}), "{read}");
    // An id this session never sent (or not a hash at all) reads nothing.
    let other = sha256_hex(b"someone else's image");
    for wrong in [other.as_str(), "../../etc/passwd"] {
        let refused =
            c.call("_acpmux/attachment", json!({"sessionId": session, "id": wrong})).await;
        assert!(refused.get("error").is_some(), "{wrong}: {refused}");
    }

    first.shutdown_all().await;
    drop(c);
    drop(first);
    let second = hub(&store);
    let mut c = client(&second);
    assert_eq!(user_messages(&mut c, &session).await[0]["images"][0]["id"], json!(id));
    let read = c.call("_acpmux/attachment", json!({"sessionId": session, "id": id})).await;
    assert_eq!(read["result"]["data"], json!(PNG), "{read}");
}

/// An image block of `bytes`, and its attachment id.
fn image(bytes: &[u8], mime: &str, name: &str) -> (Value, String) {
    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD.encode(bytes);
    (json!({"type": "image", "mimeType": mime, "data": data, "name": name}), sha256_hex(bytes))
}

async fn new_session(c: &mut Client) -> String {
    let created = c
        .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}}))
        .await;
    created["result"]["sessionId"].as_str().unwrap().to_owned()
}

/// Waits (test polling) until `session`'s transcript has a record `pred` accepts.
async fn wait_event(c: &mut Client, session: &str, what: &str, pred: impl Fn(&Value) -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    loop {
        let page =
            c.call("_acpmux/events", json!({"sessionId": session, "kinds": ["transcript"]})).await;
        let events = page["result"]["events"].as_array().cloned().unwrap_or_default();
        if events.iter().any(&pred) {
            return;
        }
        assert!(std::time::Instant::now() < deadline, "no {what}: {events:#?}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

fn chunk(e: &Value, text: &str) -> bool {
    e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
        && e["msg"]["params"]["update"]["content"]["text"] == text
}

/// The agent's last echo in `session` (the fake agent names each image it got).
async fn echo(c: &mut Client, session: &str) -> String {
    let page =
        c.call("_acpmux/events", json!({"sessionId": session, "kinds": ["transcript"]})).await;
    let events = page["result"]["events"].as_array().cloned().unwrap_or_default();
    let texts =
        events.iter().filter_map(|e| e["msg"]["params"]["update"]["content"]["text"].as_str());
    texts.filter(|t| t.starts_with("echo: ")).last().unwrap_or_default().to_owned()
}

/// The session's queue, as every client's list shows it.
async fn queue(c: &mut Client, session: &str) -> Vec<Value> {
    let attached = c.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
    attached["result"]["session"]["queue"].as_array().cloned().unwrap_or_default()
}

/// A turn of `session` that runs until `open` writes to its gate.
#[cfg(unix)]
async fn gated_turn(c: &mut Client, session: &str, gate: &Path) {
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: a valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let prompt = format!("gate: {}", gate.display());
    c.send(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": prompt}]}),
    )
    .await;
    wait_event(c, session, "before-gate chunk", |e| chunk(e, "before-gate")).await;
}

#[cfg(unix)]
fn open(gate: &Path) {
    use std::os::unix::fs::OpenOptionsExt;
    let mut f =
        std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(gate).unwrap();
    std::io::Write::write_all(&mut f, b"go").unwrap();
}

/// Queues a prompt with two images behind a gated turn, edits its text with `edit` (more
/// `queue_edit` params), and lets it run. Answers the queue as the edit left it, the ids of the
/// two images, and the session.
#[cfg(unix)]
async fn edit_queued(
    name: &str,
    edit: Value,
) -> (Arc<Hub>, Client, Vec<Value>, [String; 2], String) {
    let hub = hub(&store(name));
    let mut c = client(&hub);
    let session = new_session(&mut c).await;
    gated_turn(&mut c, &session, &root().join(format!("gate-{name}"))).await;
    let (first, a) = image(format!("{name} first").as_bytes(), "image/png", "first.png");
    let (second, b) = image(format!("{name} second").as_bytes(), "image/jpeg", "second.jpg");
    let mut q = client(&hub);
    let sent = q
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "look"}, first, second], "_meta": {"acpmux": {"promptId": "q-img"}}}),
        )
        .await;
    wait_event(&mut c, &session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-img"
    })
    .await;
    let mut params =
        json!({"sessionId": session, "promptId": "q-img", "op": "update", "text": "look again"});
    params.as_object_mut().unwrap().extend(edit.as_object().unwrap().clone());
    let edited = c.call("_acpmux/queue_edit", params).await;
    assert_eq!(edited["result"]["ok"], true, "{edited}");
    let queued = queue(&mut c, &session).await;
    open(&root().join(format!("gate-{name}")));
    let answer = q.reply(sent).await;
    assert_eq!(answer["result"]["stopReason"], "end_turn", "{answer}");
    (hub, c, queued, [a, b], session)
}

#[cfg(unix)]
#[tokio::test]
async fn editing_a_queued_prompts_text_keeps_its_images() {
    let (_hub, mut c, queued, [a, b], session) = edit_queued("edit-keeps", json!({})).await;
    let names = json!([
        {"id": a, "mimeType": "image/png", "name": "first.png"},
        {"id": b, "mimeType": "image/jpeg", "name": "second.jpg"},
    ]);
    // The agent got both images after the edited text, and the sent message names them.
    assert_eq!(echo(&mut c, &session).await, format!("echo: look again image:{a} image:{b}"));
    let sent = user_messages(&mut c, &session).await;
    let sent = sent.iter().find(|m| m["promptId"] == "q-img").expect("the queued prompt ran");
    assert_eq!(sent["text"], "look again");
    assert_eq!(sent["images"], names, "{sent}");
    // Its row listed them while it waited.
    assert_eq!(queued[0]["images"], names, "{queued:#?}");
}

#[cfg(unix)]
#[tokio::test]
async fn editing_a_queued_prompt_keeps_only_the_images_it_names() {
    let (_hub, mut c, queued, [a, _], session) = {
        // The edit names the first image only: the second was removed from the row.
        let name = "edit-names";
        let (_, a) = image(format!("{name} first").as_bytes(), "image/png", "first.png");
        edit_queued(name, json!({"images": [a]})).await
    };
    let names = json!([{"id": a, "mimeType": "image/png", "name": "first.png"}]);
    assert_eq!(echo(&mut c, &session).await, format!("echo: look again image:{a}"));
    let sent = user_messages(&mut c, &session).await;
    let sent = sent.iter().find(|m| m["promptId"] == "q-img").expect("the queued prompt ran");
    assert_eq!(sent["images"], names, "{sent}");
    assert_eq!(queued[0]["images"], names, "{queued:#?}");
}

#[cfg(unix)]
#[tokio::test]
async fn a_queued_prompts_images_are_listed_and_read_back_before_it_runs() {
    let name = "queued-read";
    let hub = hub(&store(name));
    let mut c = client(&hub);
    let session = new_session(&mut c).await;
    let other = new_session(&mut c).await;
    let gate = root().join(format!("gate-{name}"));
    gated_turn(&mut c, &session, &gate).await;
    let (shot, id) = image(b"a queued screenshot", "image/png", "shot.png");
    let data = shot["data"].clone();
    let mut q = client(&hub);
    let sent = q
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "see"}, shot], "_meta": {"acpmux": {"promptId": "q-shot"}}}),
        )
        .await;
    wait_event(&mut c, &session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-shot"
    })
    .await;

    // Its row can show it before it runs (after a reload too: the log names it).
    let read = c.call("_acpmux/attachment", json!({"sessionId": session, "id": id})).await;
    assert_eq!(read["result"], json!({"mimeType": "image/png", "data": data}), "{read}");
    let queued = queue(&mut c, &session).await;
    assert_eq!(
        queued[0]["images"],
        json!([{"id": id, "mimeType": "image/png", "name": "shot.png"}]),
        "{queued:#?}"
    );
    // Not to another chat, and an id this one never named reads nothing.
    let refused = c.call("_acpmux/attachment", json!({"sessionId": other, "id": id})).await;
    assert!(refused.get("error").is_some(), "{refused}");
    let unknown = sha256_hex(b"never sent");
    let refused = c.call("_acpmux/attachment", json!({"sessionId": session, "id": unknown})).await;
    assert!(refused.get("error").is_some(), "{refused}");

    open(&gate);
    let answer = q.reply(sent).await;
    assert_eq!(answer["result"]["stopReason"], "end_turn", "{answer}");
}
