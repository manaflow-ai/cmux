//! Images sent with a prompt stay with the chat (Leo, 2026-10-13: a sent prompt's images
//! vanished). The prompt's `user_message` names each image by its content hash, the bytes are
//! kept once under `<ACPMUX_HOME>/attachments`, and `_acpmux/attachment` hands an image back to
//! whoever can read the session, also after a restart. An id the session never sent reads nothing.
//!
//! A queued prompt keeps its images too (Leo, 2026-10-21: his queued row showed text only, and
//! editing the queued text dropped the screenshot): the queue lists them, they read back before
//! the prompt runs, and an edit of its text keeps them (or only the ones it names).
//!
//! A prompt's pasted text blocks (`_meta.cmux.pasted`, the composer's) are named on its
//! `user_message` and `queued` records as UTF-16 ranges of the text, so the chat folds each
//! into a "Pasted text" chip.

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
    events
        .iter()
        .filter_map(|e| e["msg"]["params"]["update"]["content"]["text"].as_str())
        .rfind(|t| t.starts_with("echo: "))
        .unwrap_or_default()
        .to_owned()
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

/// A text block the composer marks as pasted (`_meta.cmux.pasted`).
fn pasted(text: &str) -> Value {
    json!({"type": "text", "text": text, "_meta": {"cmux": {"pasted": true}}})
}

/// `text` from UTF-16 offset `start` to `end`, as JS `text.slice(start, end)` reads it.
fn utf16_slice(text: &str, range: &Value) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    let (start, end) = (range["start"].as_u64().unwrap(), range["end"].as_u64().unwrap());
    String::from_utf16(&units[start as usize..end as usize]).unwrap()
}

// A sent prompt names the parts that were pasted (`pasted: [{start, end}]`, UTF-16 offsets
// into its text), so the chat can fold each into a "Pasted text" chip.
#[tokio::test]
async fn a_prompts_pasted_blocks_are_named_by_their_utf16_range_in_its_text() {
    let hub = hub(&store("pasted"));
    let mut c = client(&hub);
    let session = new_session(&mut c).await;
    // 👀 is outside the BMP: two UTF-16 units, four bytes, one char.
    let reply = c
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [
                {"type": "text", "text": "see 👀 this"},
                pasted("line one\nline two"),
                pasted("ünïcode"),
            ], "_meta": {"acpmux": {"promptId": "p-paste"}}}),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    let sent = user_messages(&mut c, &session).await;
    let sent = sent.iter().find(|m| m["promptId"] == "p-paste").expect("the prompt ran");
    let text = sent["text"].as_str().unwrap();
    assert_eq!(text, "see 👀 this\nline one\nline two\nünïcode");
    assert_eq!(
        sent["pasted"],
        json!([{"start": 12, "end": 29}, {"start": 30, "end": 37}]),
        "{sent}"
    );
    let parts: Vec<String> =
        sent["pasted"].as_array().unwrap().iter().map(|r| utf16_slice(text, r)).collect();
    assert_eq!(parts, ["line one\nline two", "ünïcode"]);
}

#[tokio::test]
async fn a_prompt_with_nothing_pasted_names_no_pasted_range() {
    let hub = hub(&store("not-pasted"));
    let mut c = client(&hub);
    let session = new_session(&mut c).await;
    let reply = c
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [
                {"type": "text", "text": "typed"},
                {"type": "text", "text": "also typed", "_meta": {"cmux": {"pasted": false}}},
            ], "_meta": {"acpmux": {"promptId": "p-typed"}}}),
        )
        .await;
    assert!(reply.get("error").is_none(), "{reply}");
    let sent = user_messages(&mut c, &session).await;
    let sent = sent.iter().find(|m| m["promptId"] == "p-typed").expect("the prompt ran");
    assert_eq!(sent["text"], "typed\nalso typed");
    assert!(sent.get("pasted").is_none(), "{sent}");
}

// A queued prompt's row names its pasted parts too, and so does its message once it runs.
#[cfg(unix)]
#[tokio::test]
async fn a_queued_prompts_pasted_blocks_are_named_while_it_waits_and_once_it_runs() {
    let name = "queued-pasted";
    let hub = hub(&store(name));
    let mut c = client(&hub);
    let session = new_session(&mut c).await;
    let gate = root().join(format!("gate-{name}"));
    gated_turn(&mut c, &session, &gate).await;
    let mut q = client(&hub);
    let sent = q
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "🦀 fix"}, pasted("a log")], "_meta": {"acpmux": {"promptId": "q-paste"}}}),
        )
        .await;
    wait_event(&mut c, &session, "queued record", |e| {
        e["kind"] == "queued" && e["msg"]["promptId"] == "q-paste"
    })
    .await;
    let range = json!([{"start": 7, "end": 12}]);
    let page = c.call("_acpmux/events", json!({"sessionId": session, "kinds": ["queued"]})).await;
    let events = page["result"]["events"].as_array().cloned().unwrap_or_default();
    let queued = events.iter().find(|e| e["msg"]["promptId"] == "q-paste").expect("queued");
    assert_eq!(queued["msg"]["pasted"], range, "{queued}");
    open(&gate);
    let answer = q.reply(sent).await;
    assert_eq!(answer["result"]["stopReason"], "end_turn", "{answer}");
    let sent = user_messages(&mut c, &session).await;
    let sent = sent.iter().find(|m| m["promptId"] == "q-paste").expect("the queued prompt ran");
    assert_eq!(sent["text"], "🦀 fix\na log");
    assert_eq!(sent["pasted"], range, "{sent}");
}

/// A store that counts the records it hands a reader (`scan`, `scan_back`, `scan_kinds`,
/// `events`): a file store parses each of those, and passes a line `scan_back`'s skip names on its
/// header. Every other call goes to the store it wraps.
struct Counting {
    inner: Box<dyn acpmux::store::Store>,
    parsed: Arc<std::sync::atomic::AtomicUsize>,
}

impl Counting {
    fn count(&self) {
        self.parsed.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
}

impl acpmux::store::Store for Counting {
    fn list(&self) -> anyhow::Result<Vec<acpmux::store::SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<acpmux::store::SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &acpmux::store::SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &acpmux::store::EventRecord) -> anyhow::Result<()> {
        self.inner.append(id, record)
    }
    fn events(
        &self,
        id: &str,
        after: u64,
        limit: usize,
    ) -> anyhow::Result<Vec<acpmux::store::EventRecord>> {
        let events = self.inner.events(id, after, limit)?;
        self.parsed.fetch_add(events.len(), std::sync::atomic::Ordering::SeqCst);
        Ok(events)
    }
    fn scan(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(acpmux::store::EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        self.inner.scan(id, after, &mut |rec| {
            self.count();
            visit(rec)
        })
    }
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(acpmux::store::EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        self.inner.scan_back(id, after, before, skip, &mut |rec| {
            self.count();
            visit(rec)
        })
    }
    fn tail_after(&self, id: &str, after: u64) -> anyhow::Result<(u64, u64)> {
        self.inner.tail_after(id, after)
    }
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(acpmux::store::EventRecord) -> bool,
    ) -> anyhow::Result<()> {
        self.inner.scan_kinds(id, kinds, &mut |rec| {
            self.count();
            visit(rec)
        })
    }
    fn flush(&self) -> anyhow::Result<()> {
        self.inner.flush()
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        self.inner.session_dir(id)
    }
    fn handoff_dir(&self) -> Option<PathBuf> {
        self.inner.handoff_dir()
    }
    fn peer_cache_dir(&self) -> Option<PathBuf> {
        self.inner.peer_cache_dir()
    }
}

/// Reading a sent image back costs the records that can name it, newest first, not the whole
/// chat (Leo, 2026-10-21: a pasted image showed as an empty box; reading one image of his 701 MB
/// coordinator chat took 16.7 s, as `_acpmux/attachment` parsed every record from the first).
#[tokio::test]
async fn reading_a_sent_image_back_parses_only_the_records_that_can_name_it() {
    let dir = store("image-read-cost");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let parsed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counting =
        Counting { inner: acpmux::store::open(&cfg.store, &dir).unwrap(), parsed: parsed.clone() };
    // A long chat: an image prompt early on, then thousands of the agent's own records.
    let session = "01a1-image-read-cost";
    let bytes = b"image-read-cost: a pasted screenshot";
    let id = sha256_hex(bytes);
    let attachments = acpmux::config::home().join("attachments");
    std::fs::create_dir_all(&attachments).unwrap();
    std::fs::write(attachments.join(&id), bytes).unwrap();
    let record = |seq: u64, dir: &str, kind: &str, msg: Value| acpmux::store::EventRecord {
        seq,
        at: seq,
        dir: dir.into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    use acpmux::store::Store as _;
    counting
        .append(
            session,
            &record(
                1,
                "mux",
                "user_message",
                json!({"text": "look", "images": [{"id": id, "mimeType": "image/png"}]}),
            ),
        )
        .unwrap();
    for seq in 2..=4000 {
        let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "words "}}}});
        counting.append(session, &record(seq, "in", "agent_message_chunk", update)).unwrap();
    }
    counting
        .append(session, &record(4001, "mux", "user_message", json!({"text": "and now?"})))
        .unwrap();
    counting.flush().unwrap();
    let hub = Hub::new(cfg, Box::new(counting));
    parsed.store(0, std::sync::atomic::Ordering::SeqCst);
    let image = hub.prompt_image(session, &id).unwrap();
    use base64::Engine;
    assert_eq!(image["data"], json!(base64::engine::general_purpose::STANDARD.encode(bytes)));
    let cost = parsed.load(std::sync::atomic::Ordering::SeqCst);
    assert!(cost <= 2, "reading one image parsed {cost} of the chat's 4001 records");
    // An image the chat never sent is refused without reading its log.
    parsed.store(0, std::sync::atomic::Ordering::SeqCst);
    assert!(hub.prompt_image(session, &sha256_hex(b"never sent")).is_err());
    assert_eq!(parsed.load(std::sync::atomic::Ordering::SeqCst), 0);
}

/// A hub over its own local store under `name`, its sessions' logs holding `records`.
fn hub_with(name: &str, records: &[(&str, acpmux::store::EventRecord)]) -> Arc<Hub> {
    let dir = store(name);
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let local = acpmux::store::open(&cfg.store, &dir).unwrap();
    for (session, record) in records {
        local.append(session, record).unwrap();
    }
    local.flush().unwrap();
    Hub::new(cfg, local)
}

fn mux_record(seq: u64, kind: &str, msg: Value) -> acpmux::store::EventRecord {
    acpmux::store::EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    }
}

/// Keeps `bytes` where prompts keep their images, and returns their id. The home is set first
/// (`root`), so they land where the hub reads them.
fn kept(bytes: &[u8]) -> String {
    root();
    let id = sha256_hex(bytes);
    let attachments = acpmux::config::home().join("attachments");
    std::fs::create_dir_all(&attachments).unwrap();
    std::fs::write(attachments.join(&id), bytes).unwrap();
    id
}

/// One image is one set of bytes, whichever prompts sent it and however each labelled it: it
/// reads back as the type its bytes are, whichever record the newest-first read finds. Bytes of
/// no known type keep the newest label. An id named twice in one prompt reads back once.
#[tokio::test]
async fn a_sent_image_reads_back_as_the_type_its_bytes_are_whatever_its_prompts_said() {
    use base64::Engine;
    let png = base64::engine::general_purpose::STANDARD.decode(PNG).unwrap();
    let png_id = kept(&png);
    let plain = b"conflicting-types: bytes of no known image type";
    let plain_id = kept(plain);
    let named = |id: &str, mime: &str| json!({"id": id, "mimeType": mime, "name": "image.png"});
    let prompt = |seq: u64, images: Vec<Value>| {
        mux_record(seq, "user_message", json!({"text": "look", "images": images}))
    };
    let hub = hub_with(
        "conflicting-types",
        &[
            // Sent first as a JPEG, then as a PNG: newest first finds the PNG label.
            ("png-then", prompt(1, vec![named(&png_id, "image/jpeg")])),
            ("png-then", prompt(2, vec![named(&png_id, "image/png")])),
            // Sent first as a PNG, then (queued) as a WebP: newest first finds the WebP label.
            ("png-now", prompt(1, vec![named(&png_id, "image/png")])),
            ("png-now", mux_record(2, "queued", json!({"images": [named(&png_id, "image/webp")]}))),
            // Bytes no header names, labelled twice, and named twice in the newest prompt.
            ("plain", prompt(1, vec![named(&plain_id, "image/png")])),
            (
                "plain",
                prompt(2, vec![named(&plain_id, "image/gif"), named(&plain_id, "image/gif")]),
            ),
        ],
    );
    for session in ["png-then", "png-now"] {
        let image = hub.prompt_image(session, &png_id).unwrap();
        assert_eq!(image["mimeType"], json!("image/png"), "{session}");
        assert_eq!(image["data"], json!(PNG), "{session}");
    }
    let image = hub.prompt_image("plain", &plain_id).unwrap();
    assert_eq!(image["mimeType"], json!("image/gif"));
    assert_eq!(image["data"], json!(base64::engine::general_purpose::STANDARD.encode(plain)));
}

/// The newest-first read takes a log in 64 KiB blocks from its end: a record whose text has a
/// multibyte character cut by a block edge still parses whole, so its image reads back.
#[tokio::test]
async fn a_sent_image_whose_record_spans_a_block_edge_mid_character_reads_back() {
    use base64::Engine;
    let png = base64::engine::general_purpose::STANDARD.decode(PNG).unwrap();
    let mut bytes = png.clone();
    bytes.extend_from_slice(b"block-edge");
    let id = kept(&bytes);
    // The prompt's text is 3-byte characters, longer than a block. One of three paddings of the
    // record after it puts the block edge inside a character.
    let text = "€".repeat(40_000);
    let mut found = false;
    for pad in 0..3 {
        let session = format!("block-edge-{pad}");
        let hub = hub_with(
            &format!("block-edge-{pad}"),
            &[
                (
                    session.as_str(),
                    mux_record(
                        1,
                        "user_message",
                        json!({"text": text, "images": [{"id": id, "mimeType": "image/png"}]}),
                    ),
                ),
                (session.as_str(), mux_record(2, "user_message", json!({"text": "x".repeat(pad)}))),
            ],
        );
        let segment =
            root().join(format!("block-edge-{pad}")).join("sessions").join(&session).join("events");
        let files: Vec<_> =
            std::fs::read_dir(&segment).unwrap().map(|e| e.unwrap().path()).collect();
        assert_eq!(files.len(), 1, "one segment");
        let log = std::fs::read(&files[0]).unwrap();
        let edge = log.len() - 64 * 1024;
        if !(0x80..0xc0).contains(&log[edge]) {
            continue;
        }
        found = true;
        let image = hub.prompt_image(&session, &id).unwrap();
        assert_eq!(image["data"], json!(base64::engine::general_purpose::STANDARD.encode(&bytes)));
        assert_eq!(image["mimeType"], json!("image/png"));
    }
    assert!(found, "no padding put the block edge inside a character");
}

/// Older records that name the image sit behind the newest one that does: the read stops at
/// the newest and parses none of them.
#[tokio::test]
async fn reading_a_sent_image_back_stops_at_the_newest_record_that_names_it() {
    let dir = store("image-read-newest");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let parsed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counting =
        Counting { inner: acpmux::store::open(&cfg.store, &dir).unwrap(), parsed: parsed.clone() };
    let session = "01a1-image-read-newest";
    let id = kept(b"image-read-newest: sent three times");
    let names = json!({"text": "again", "images": [{"id": id, "mimeType": "image/png"}]});
    use acpmux::store::Store as _;
    // Sent in a prompt, queued, sent again, then the agent's own records, then sent once more.
    counting.append(session, &mux_record(1, "user_message", names.clone())).unwrap();
    counting.append(session, &mux_record(2, "queued", json!({"images": names["images"]}))).unwrap();
    counting.append(session, &mux_record(3, "user_message", names.clone())).unwrap();
    for seq in 4..=1000 {
        let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "words "}}}});
        counting
            .append(
                session,
                &acpmux::store::EventRecord {
                    seq,
                    at: seq,
                    dir: "in".into(),
                    kind: "agent_message_chunk".into(),
                    msg: update,
                    host_seq: None,
                },
            )
            .unwrap();
    }
    counting.append(session, &mux_record(1001, "user_message", names.clone())).unwrap();
    counting.flush().unwrap();
    let hub = Hub::new(cfg, Box::new(counting));
    parsed.store(0, std::sync::atomic::Ordering::SeqCst);
    assert!(hub.prompt_image(session, &id).is_ok());
    assert_eq!(parsed.load(std::sync::atomic::Ordering::SeqCst), 1);
}
