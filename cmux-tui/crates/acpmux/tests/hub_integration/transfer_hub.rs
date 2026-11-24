//! A chat moved through the team hub (`hub/transfer_pull.rs`): machine B takes mesh control op
//! `move` from machine A, builds its own guard, makes or checks the folder, pulls the bundle's
//! pages from A and imports it. The hub's delivery is the control hook called as the relay calls
//! it; A's pages come through an in-process stand-in for the carrier circuit that names the
//! dialer as the circuit's Noise handshake does (`transfer_service.rs` serves the real one, and
//! `tests/hub_carrier.rs` runs it over the relay).
//!
//! - the chat lands on B with its history and queue, each queued prompt run once there, under
//!   the guard's `peer` control;
//! - a dialer other than the move's `to.hub` reads no page;
//! - a sender that is not this machine's person, or an entry that does not list `move`, is
//!   refused before anything runs;
//! - a folder outside B's `webRoots` is refused, and the chat stays frozen on A;
//! - a lost ack, or the same move sent again, imports the chat once;
//! - a manifest past one hub message (64 KiB) goes by reference and the target pulls it over the
//!   circuit, the chat landing whole; a small one still goes inline as version 1;
//! - a target too old to pull a manifest refuses with the old words, and the source answers a
//!   clear refusal the client aborts the move on, so the chat is not left frozen.

use super::transfer::texts;
use super::*;
use acpmux::hub::transfer_pull::{MANIFEST_PULL_VERSION, MAX_BODY, OLD_VERSION_REFUSAL};
use acpmux::hub::transfer_pull::{PageSource, TransferDial};
use acpmux::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt,
};
use acpmux::mesh_http::MeshControlFrom;
use acpmux::rpc::RpcError;
use acpmux::server::mesh_relay::{ControlHook, MeshControlHook};
use futures::future::BoxFuture;
use std::path::{Path, PathBuf};

const A_KEY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
const B_KEY: &str = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
const C_KEY: &str = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=";

/// A folder of one test, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn under(parent: &Path, tag: &str) -> Self {
        let dir = parent.join(format!("acpmux-hub-move-{tag}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(std::fs::canonicalize(&dir).unwrap())
    }

    /// Under the home directory: a guard's roots must be.
    fn home(tag: &str) -> Self {
        Self::under(&dirs::home_dir().expect("a home directory"), tag)
    }

    fn text(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The carrier circuit to A as B dials it: every request names `from`, the key the circuit's
/// handshake proved, and reaches A's `transfer_source_page`.
struct Direct {
    source: Arc<Hub>,
    from: String,
}

struct DirectPages {
    source: Arc<Hub>,
    from: String,
}

impl PageSource for DirectPages {
    fn call<'a>(
        &'a mut self,
        method: &'a str,
        params: Value,
    ) -> BoxFuture<'a, Result<Value, RpcError>> {
        Box::pin(async move { self.source.transfer_source_page(&self.from, method, &params).await })
    }
}

impl TransferDial for Direct {
    fn open<'a>(&'a self, daemon: &'a str) -> BoxFuture<'a, Result<Box<dyn PageSource>, String>> {
        Box::pin(async move {
            if daemon != A_KEY {
                return Err(format!("no machine {daemon}"));
            }
            let pages = DirectPages { source: self.source.clone(), from: self.from.clone() };
            Ok(Box::new(pages) as Box<dyn PageSource>)
        })
    }
}

/// B's control hook as `host join` writes it, with `move` listed, for person `user-1`.
fn hook(ledger: &Path, ops: &[&str]) -> MeshControlHook {
    let entry = MeshControlFrom {
        daemon_id: String::new(),
        max_policy: None,
        same_user: true,
        ops: ops.iter().map(|o| (*o).to_owned()).collect(),
        max_policy: None,
    };
    MeshControlHook::new(vec![entry], Some(ledger.join("mesh-controls.json")))
        .with_own_user(Arc::new(|| Some("user-1".to_owned())))
}

/// Op `move` as the hub delivers it to B: from A's daemon, stamped with `user`.
fn move_message(message_id: &str, user: &str, body: &Value) -> InMessage {
    serde_json::from_value(json!({
        "messageId": message_id, "kind": "control", "op": "move", "mode": "now",
        "to": {"daemonId": B_KEY},
        "from": {"daemonId": A_KEY, "user": user, "host": "machine-a"},
        "body": body.to_string(),
    }))
    .unwrap()
}

fn ack_json(ack: &Ack) -> Value {
    serde_json::to_value(ack).unwrap()
}

/// The `msg` of every record of `kind` in a session's log.
async fn records(c: &mut TestClient, id: &str, kind: &str) -> Vec<Value> {
    let page = c
        .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
        .await
        .unwrap();
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == kind)
        .map(|e| e["msg"].clone())
        .collect()
}

fn prompt(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}})
}

/// A chat with a reply in its history and a turn running with `queued` behind it.
async fn busy_chat(c: &mut TestClient, queued: &[(&str, &str)]) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "p-hi", "hi")).await.unwrap();
    c.send(method::SESSION_PROMPT, prompt(&id, "p-turn", "until-cancel")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    for (prompt_id, text) in queued {
        c.send(method::SESSION_PROMPT, prompt(&id, prompt_id, text)).await;
        c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
            p["promptId"] == *prompt_id && p["queued"] == true
        })
        .await;
    }
    id
}

/// A on one side, B on the other, B with `root` as its one webRoot and A behind the dialer
/// that names `dialer` as B's key.
async fn machines(root: &Scratch, dialer: &str) -> (Arc<Hub>, TestClient, Arc<Hub>, TestClient) {
    // A guarded receive takes only a plain agent session id (`transfer_guard.rs`).
    let env = || BTreeMap::from([("FAKE_SESSION_PREFIX".to_owned(), "fake-session-".to_owned())]);
    let (a, src) = setup_env(PermissionPolicy::ApproveAll, env()).await;
    let (b, dst) = setup_env(PermissionPolicy::ApproveAll, env()).await;
    {
        let mut cfg = b.config.write().await;
        cfg.web_roots = vec![root.text()];
        // A chat under the guard's `peer` control runs only in a mode that asks (`resolve.rs`).
        cfg.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    }
    b.set_transfer_dial(Arc::new(Direct { source: a.clone(), from: dialer.to_owned() }));
    (a, src, b, dst)
}

/// Begins the hub move of `id` on A to B, and op `move`'s body for it in `folder`.
async fn begin(src: &mut TestClient, id: &str, folder: Value) -> (Value, Value) {
    let begin = src
        .request(
            "_acpmux/transfer_begin",
            json!({"sessionId": id, "interrupt": true, "gatesQueueApproval": true,
                   "to": {"hub": B_KEY, "host": "machine-b"}}),
        )
        .await
        .unwrap();
    let body = json!({"version": 1, "transferId": begin["transferId"], "sessionId": id,
                      "manifest": begin, "folder": folder, "branch": "lane/x", "commit": "c0ffee"});
    (begin, body)
}

#[tokio::test]
async fn a_chat_moved_through_the_hub_lands_with_its_queue_and_runs_it_once_under_peer() {
    let root = Scratch::home("lands");
    let ledger = tempfile::tempdir().unwrap();
    let (_a, mut src, b, mut dst) = machines(&root, B_KEY).await;
    let id = busy_chat(&mut src, &[("p-a", "a"), ("p-b", "b")]).await;
    let (begin, body) = begin(&mut src, &id, json!({"cwd": root.text()})).await;

    let ack =
        hook(ledger.path(), &["move"]).control(&b, &move_message("m-1", "user-1", &body)).await;
    let ack = ack_json(&ack.expect("an answer within the hook's wait"));
    assert_eq!(ack["state"], "delivered", "{ack}");
    let moved: Value = serde_json::from_str(ack["result"].as_str().unwrap()).unwrap();
    assert_eq!(moved["sessionId"], id.as_str(), "{moved}");
    assert_eq!(moved["cwd"], root.text(), "{moved}");
    assert_eq!(
        (moved["branch"].as_str(), moved["commit"].as_str()),
        (Some("lane/x"), Some("c0ffee"))
    );

    let to = json!({"host": "machine-b", "via": "hub", "sessionId": id, "cwd": moved["cwd"]});
    let committed = src
        .request(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begin["transferId"], "to": to, "epoch": begin["epoch"]}),
        )
        .await
        .unwrap();
    assert_eq!(committed["committed"], true, "{committed}");

    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !texts(&mut dst, &id, "user_message").await.contains(&"b".to_owned()) {
        assert!(tokio::time::Instant::now() < deadline, "the moved queue never ran");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    let ran_there = texts(&mut dst, &id, "user_message").await;
    assert_eq!(ran_there[..2], ["hi", "until-cancel"], "history: {ran_there:?}");
    assert_eq!(ran_there[ran_there.len() - 2..], ["a", "b"], "the queue once: {ran_there:?}");
    assert_eq!(ran_there.iter().filter(|t| *t == "a").count(), 1, "{ran_there:?}");
    let ran_here = texts(&mut src, &id, "user_message").await;
    assert_eq!(ran_here, ["hi", "until-cancel"], "the source ran nothing after the move began");

    let guarded = records(&mut dst, &id, "transfer_guarded").await;
    assert_eq!(guarded.len(), 1, "{guarded:?}");
    assert_eq!(guarded[0]["control"], "peer", "{guarded:?}");
    let landed = records(&mut dst, &id, "transferred_in").await;
    assert_eq!(landed.len(), 1, "{landed:?}");
    assert_eq!(landed[0]["from"]["via"], "hub", "{landed:?}");
    assert_eq!(landed[0]["from"]["daemonId"], A_KEY, "{landed:?}");
    let arrived = dst.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(arrived["cwd"], root.text(), "{arrived}");
    let left = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(left["status"], "closed", "{left}");
}

#[tokio::test]
async fn a_dialer_the_move_does_not_name_reads_no_page_and_the_chat_stays_frozen() {
    let root = Scratch::home("wrong-dialer");
    let ledger = tempfile::tempdir().unwrap();
    // B dials A, but the circuit's proven key is C's: A's move names B.
    let (a, mut src, b, mut dst) = machines(&root, C_KEY).await;
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;
    let (begin, body) = begin(&mut src, &id, json!({"cwd": root.text()})).await;

    let ack =
        hook(ledger.path(), &["move"]).control(&b, &move_message("m-2", "user-1", &body)).await;
    let ack = ack_json(&ack.unwrap());
    assert_eq!(ack["state"], "refused", "{ack}");
    assert!(ack["detail"].as_str().unwrap().contains("transfer.not_yours"), "{ack}");
    // Asked directly too: no page, no renew, for any key but B's.
    let read = json!({"transferId": begin["transferId"], "path": "session.json", "offset": 0,
                      "epoch": begin["epoch"]});
    for key in [C_KEY, "", A_KEY] {
        let refused = a.transfer_source_page(key, "read", &read).await.unwrap_err();
        assert!(refused.message.contains("not_yours"), "{key}: {}", refused.message);
    }
    assert!(a.transfer_source_page(B_KEY, "read", &read).await.is_ok(), "B reads its move");
    let commit = json!({"sessionId": id, "transferId": begin["transferId"]});
    assert!(a.transfer_source_page(B_KEY, "commit", &commit).await.is_err(), "only read and renew");

    assert!(dst.request(method::MUX_INFO, json!({"sessionId": id})).await.is_err(), "not on B");
    let here = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(here["moving"], true, "frozen on A until the move ends: {here}");
}

#[tokio::test]
async fn another_persons_sender_or_an_entry_without_move_is_refused_before_anything_runs() {
    let root = Scratch::home("other-person");
    let ledger = tempfile::tempdir().unwrap();
    let (_a, mut src, b, mut dst) = machines(&root, B_KEY).await;
    let id = busy_chat(&mut src, &[]).await;
    let (_begin, body) = begin(&mut src, &id, json!({"cwd": root.text()})).await;

    let ack =
        hook(ledger.path(), &["move"]).control(&b, &move_message("m-3", "user-2", &body)).await;
    let ack = ack_json(&ack.unwrap());
    assert_eq!(ack, json!({"state": "refused", "detail": "mesh.control_not_allowed"}));
    // The person's own machine, but `move` not listed (the lifecycle default `host join` writes).
    for ops in [&["start", "resume", "stop"][..], &["read"][..], &[][..]] {
        let ack = hook(ledger.path(), ops).control(&b, &move_message("m-4", "user-1", &body)).await;
        assert_eq!(ack_json(&ack.unwrap())["detail"], "mesh.control_not_allowed", "{ops:?}");
    }
    assert!(dst.request(method::MUX_INFO, json!({"sessionId": id})).await.is_err(), "not on B");
}

#[tokio::test]
async fn a_folder_outside_the_targets_roots_is_refused_and_the_chat_stays_frozen() {
    let root = Scratch::home("roots");
    let outside = Scratch::under(&std::env::temp_dir(), "outside");
    let ledger = tempfile::tempdir().unwrap();
    let (_a, mut src, b, mut dst) = machines(&root, B_KEY).await;
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;
    let (_begin, body) = begin(&mut src, &id, json!({"cwd": outside.text()})).await;

    let ack =
        hook(ledger.path(), &["move"]).control(&b, &move_message("m-5", "user-1", &body)).await;
    let ack = ack_json(&ack.unwrap());
    assert_eq!(ack["state"], "refused", "{ack}");
    assert!(ack["detail"].as_str().unwrap().contains("transfer.cwd"), "{ack}");
    assert!(dst.request(method::MUX_INFO, json!({"sessionId": id})).await.is_err(), "not on B");
    let here = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(here["moving"], true, "frozen on A: {here}");
    assert_eq!(texts(&mut src, &id, "user_message").await, ["hi", "until-cancel"]);

    // A daemon with no webRoots takes no moved chat at all.
    b.config.write().await.web_roots.clear();
    let ack =
        hook(ledger.path(), &["move"]).control(&b, &move_message("m-6", "user-1", &body)).await;
    let ack = ack_json(&ack.unwrap());
    assert!(ack["detail"].as_str().unwrap().contains("transfer.no_roots"), "{ack}");
}

#[tokio::test]
async fn a_lost_ack_or_a_move_sent_again_imports_the_chat_once() {
    let root = Scratch::home("once");
    let ledger = tempfile::tempdir().unwrap();
    let (_a, mut src, b, mut dst) = machines(&root, B_KEY).await;
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;
    let (_begin, body) = begin(&mut src, &id, json!({"cwd": root.text()})).await;
    let hook = hook(ledger.path(), &["move"]);

    let first = ack_json(&hook.control(&b, &move_message("m-7", "user-1", &body)).await.unwrap());
    assert_eq!(first["state"], "delivered", "{first}");
    // The hub leases it again (its ack was lost): the ledger answers the same, nothing runs.
    let again = ack_json(&hook.control(&b, &move_message("m-7", "user-1", &body)).await.unwrap());
    assert_eq!(again, first);
    // The same move as a new message (a ledger that lost the first): it landed, so the same answer.
    let fresh = tempfile::tempdir().unwrap();
    let other = super::transfer_hub::hook(fresh.path(), &["move"]);
    let resent = ack_json(&other.control(&b, &move_message("m-8", "user-1", &body)).await.unwrap());
    assert_eq!(resent["state"], "delivered", "{resent}");
    // The same chat and folder; `timings` only on the answer of the pull that ran.
    let moved = |ack: &Value| {
        let mut moved: Value = serde_json::from_str(ack["result"].as_str().unwrap()).unwrap();
        moved.as_object_mut().unwrap().remove("timings");
        moved
    };
    assert_eq!(moved(&resent), moved(&first), "{resent}");

    let landed = records(&mut dst, &id, "transferred_in").await;
    assert_eq!(landed.len(), 1, "one import: {landed:?}");
    let listed = dst.request(method::MUX_SESSIONS, json!({})).await.unwrap();
    let rows = listed["sessions"].as_array().unwrap();
    assert_eq!(rows.iter().filter(|s| s["sessionId"] == id.as_str()).count(), 1, "{listed}");
}

#[tokio::test]
async fn op_move_forget_drops_the_move_on_the_target_and_says_whether_it_landed() {
    let root = Scratch::home("forget");
    let (_a, mut src, b, _dst) = machines(&root, B_KEY).await;
    let id = busy_chat(&mut src, &[]).await;
    let (begin, body) = begin(&mut src, &id, json!({"cwd": root.text()})).await;
    let forget = json!({"version": 1, "transferId": begin["transferId"], "sessionId": id});
    let answer = b.transfer_pull_forget(&forget).await.unwrap();
    assert_eq!(answer["landed"], false, "{answer}");
    // A move given up is never taken later.
    let refused = b.transfer_pull(A_KEY, Some("machine-a"), &body).await.unwrap_err();
    assert!(refused.message.contains("forgotten"), "{}", refused.message);
}

/// A's hosted control inbox as a stand-in: each control goes to B's real hook, stamped from A,
/// and its body is kept. `old` plays a target whose acpmux takes only version 1: it refuses
/// any other with the words an old build's `run_control` answers.
struct Mesh {
    target: std::sync::Weak<Hub>,
    hook: MeshControlHook,
    old: bool,
    sent: std::sync::Mutex<Vec<Value>>,
}

impl MeshHub for Mesh {
    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            let body: Value = serde_json::from_str(&m.body).unwrap();
            self.sent.lock().unwrap().push(body.clone());
            let answer = if self.old && body["version"] != 1 {
                Ack::refused(OLD_VERSION_REFUSAL)
            } else {
                let message = move_message(&m.idempotency_key, "user-1", &body);
                self.hook.control(&self.target.upgrade().unwrap(), &message).await.unwrap()
            };
            let mut receipt = serde_json::to_value(answer).unwrap();
            receipt["messageId"] = json!(m.idempotency_key);
            Ok(serde_json::from_value(receipt).unwrap())
        })
    }
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        unreachable!("controls are delivered in send")
    }
    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        unreachable!("send returns the final answer")
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        unreachable!("send returns the final receipt")
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        unreachable!("no heartbeat here")
    }
}

/// A joined to the stand-in hub that carries its controls to B.
fn join(a: &Hub, b: &Arc<Hub>, ledger: &Path, old: bool) -> Arc<Mesh> {
    let mesh = Arc::new(Mesh {
        target: Arc::downgrade(b),
        hook: hook(ledger, &["move"]),
        old,
        sent: Default::default(),
    });
    a.mesh.set(mesh.clone());
    mesh
}

/// A request whose error comes back whole, `data` and all (`TestClient::request` keeps only
/// its message).
async fn request_whole(c: &mut TestClient, m: &str, params: Value) -> Result<Value, RpcError> {
    use acpmux::rpc::Message;
    c.next += 1;
    let id = c.next;
    c.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(60), c.rx.recv())
            .await
            .expect("an answer")
            .expect("connection open");
        if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
            && rid == id
        {
            return match error {
                Some(e) => Err(e),
                None => Ok(result.unwrap_or(Value::Null)),
            };
        }
    }
}

/// A chat whose move manifest is past one hub message: a turn running and `n` prompts queued
/// behind it, each listed in the manifest's summary with its preview.
async fn long_chat(c: &mut TestClient, n: usize) -> (String, Vec<(String, String)>) {
    let queued: Vec<(String, String)> = (0..n)
        .map(|i| (format!("p-{i}"), format!("queued {i}: {}", "the long chat's words ".repeat(12))))
        .collect();
    let refs: Vec<(&str, &str)> = queued.iter().map(|(p, t)| (p.as_str(), t.as_str())).collect();
    (busy_chat(c, &refs).await, queued)
}

/// `_acpmux/transfer_hub` on A for a move begun with `begin`, as the client sends it.
fn hub_move(id: &str, begin: &Value, folder: Value) -> Value {
    json!({"sessionId": id, "transferId": begin["transferId"], "epoch": begin["epoch"],
           "manifest": begin, "folder": folder, "host": "machine-b"})
}

#[tokio::test]
async fn a_manifest_past_one_hub_message_is_pulled_and_the_chat_lands_whole() {
    let root = Scratch::home("pulled");
    let ledger = tempfile::tempdir().unwrap();
    let (a, mut src, b, mut dst) = machines(&root, B_KEY).await;
    let mesh = join(&a, &b, ledger.path(), false);
    let (id, queued) = long_chat(&mut src, 160).await;
    let (begin, _) = begin(&mut src, &id, json!({"cwd": root.text()})).await;
    let inline = begin.to_string().len();
    assert!(inline > MAX_BODY, "the manifest is past one hub message: {inline} bytes");

    let answer = request_whole(
        &mut src,
        "_acpmux/transfer_hub",
        hub_move(&id, &begin, json!({"cwd": root.text()})),
    )
    .await
    .unwrap();
    assert_eq!(answer["moved"]["sessionId"], id.as_str(), "{answer}");
    let sent = mesh.sent.lock().unwrap().clone();
    assert_eq!(sent.len(), 1, "one control");
    assert_eq!(sent[0]["version"], MANIFEST_PULL_VERSION, "by reference");
    assert!(sent[0].get("manifest").is_none(), "no manifest inline");
    assert_eq!(sent[0]["manifestPull"]["bytes"], begin.to_string().len(), "{}", sent[0]);
    assert!(sent[0].to_string().len() <= MAX_BODY);

    let to = json!({"host": "machine-b", "via": "hub", "sessionId": id, "cwd": root.text()});
    let committed = src
        .request(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begin["transferId"], "to": to, "epoch": begin["epoch"]}),
        )
        .await
        .unwrap();
    assert_eq!(committed["committed"], true, "{committed}");
    let last = &queued.last().unwrap().1;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while !texts(&mut dst, &id, "user_message").await.contains(last) {
        assert!(tokio::time::Instant::now() < deadline, "the moved queue never ran");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let ran_there = texts(&mut dst, &id, "user_message").await;
    assert_eq!(ran_there[..2], ["hi", "until-cancel"], "history: {ran_there:?}");
    let expected: Vec<&String> = queued.iter().map(|(_, t)| t).collect();
    // The cut turn's resume notice runs first (`until-cancel` was running): then the queue.
    let ran_queue: Vec<&String> = ran_there.iter().filter(|t| t.starts_with("queued ")).collect();
    assert_eq!(ran_queue, expected, "the queue, once, in order");
    assert_eq!(records(&mut dst, &id, "transferred_in").await.len(), 1);
    let left = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(left["status"], "closed", "{left}");
}

#[tokio::test]
async fn an_old_target_refuses_a_pulled_manifest_clearly_and_the_chat_is_given_back() {
    let root = Scratch::home("old-target");
    let ledger = tempfile::tempdir().unwrap();
    let (a, mut src, b, mut dst) = machines(&root, B_KEY).await;
    let mesh = join(&a, &b, ledger.path(), true);
    let (id, _) = long_chat(&mut src, 160).await;
    let (begin, _) = begin(&mut src, &id, json!({"cwd": root.text()})).await;
    let kib = begin.to_string().len().div_ceil(1024);

    let refused = request_whole(
        &mut src,
        "_acpmux/transfer_hub",
        hub_move(&id, &begin, json!({"cwd": root.text()})),
    )
    .await
    .unwrap_err();
    assert_eq!(mesh.sent.lock().unwrap()[0]["version"], MANIFEST_PULL_VERSION);
    let data = refused.data.clone().unwrap_or(Value::Null);
    assert_eq!(data["refused"], true, "the client aborts on it: {refused:?}");
    assert_eq!(data["reason"], "transfer.target_too_old", "{refused:?}");
    assert!(
        refused
            .message
            .contains("the target's acpmux is too old to take a move manifest over 64 KiB")
            && refused.message.contains("`acpmux machine update machine-b`")
            && refused.message.contains("or move a smaller chat"),
        "{}",
        refused.message
    );
    // The chat's own size is named, within a KiB or so of the body the source would have sent.
    assert!(
        (kib..kib + 2).any(|k| refused.message.contains(&format!("({k} KiB)"))),
        "{}",
        refused.message
    );
    assert!(dst.request(method::MUX_INFO, json!({"sessionId": id})).await.is_err(), "not on B");

    // What the client does on a refusal (`session_move_hub.rs` `Moving::run`): the move is
    // aborted, and the chat runs here again with its queue.
    let abort =
        json!({"sessionId": id, "transferId": begin["transferId"], "epoch": begin["epoch"]});
    src.request("_acpmux/transfer_abort", abort).await.unwrap();
    let here = src.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_ne!(here["moving"], true, "not frozen: {here}");
    assert_ne!(here["status"], "closed", "{here}");
}

#[tokio::test]
async fn a_manifest_that_fits_still_goes_inline_as_version_1() {
    let root = Scratch::home("inline");
    let ledger = tempfile::tempdir().unwrap();
    let (a, mut src, b, _dst) = machines(&root, B_KEY).await;
    // An old target takes it: a small move asks nothing new of it.
    let mesh = join(&a, &b, ledger.path(), true);
    let id = busy_chat(&mut src, &[("p-a", "a")]).await;
    let (begin, _) = begin(&mut src, &id, json!({"cwd": root.text()})).await;

    let answer = request_whole(
        &mut src,
        "_acpmux/transfer_hub",
        hub_move(&id, &begin, json!({"cwd": root.text()})),
    )
    .await
    .unwrap();
    assert_eq!(answer["moved"]["sessionId"], id.as_str(), "{answer}");
    let sent = mesh.sent.lock().unwrap().clone();
    assert_eq!(sent[0]["version"], 1, "{}", sent[0]);
    assert_eq!(sent[0]["manifest"], begin, "inline");
    assert!(sent[0].get("manifestPull").is_none());
}
