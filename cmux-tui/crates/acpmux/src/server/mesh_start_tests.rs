//! A chat started from the app's new-chat picker on a machine only the mesh hub reaches, end to
//! end in one process: machine A's `session/new` with `_meta.acpmux.peer` naming hub machine B
//! posts a `start` to a stand-in hub that leases it straight to B's relay (`deliver`, with the
//! `sameUser` entry `host join` writes). B starts the chat; A answers with its id. A's first
//! prompt goes through the hub and its reply reaches A's client as a `session/update` from B. No
//! ssh peer, no peer link.

use super::*;
use crate::config::Config;
use crate::mesh::{Ack, HubError, InMessage, MeshHub, OutMessage, Receipt, Target};
use crate::mesh_http::MeshControlFrom;
use futures::future::BoxFuture;
use std::sync::Mutex;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// Machine B: takes a peer's start in `root` with an asking mode, as a hub start runs there.
fn machine_b(root: &std::path::Path) -> Arc<Hub> {
    machine_b_with(root, None, &["python3", FAKE])
}

/// Machine B with its chats in a store on disk at `store` (None: in memory), its `fake` harness
/// run as `argv`.
fn machine_b_with(
    root: &std::path::Path,
    store: Option<&std::path::Path>,
    argv: &[&str],
) -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": argv}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = match store {
        Some(_) => crate::config::StoreMode::Local,
        None => crate::config::StoreMode::Memory,
    };
    config.web_roots = vec![root.to_string_lossy().into_owned()];
    config.web_asking_modes.insert("fake".into(), vec!["normal".into(), "strict".into()]);
    let at = store.unwrap_or(std::path::Path::new("/nonexistent"));
    let store = crate::store::open(&config.store, at).unwrap();
    Hub::new(config, store)
}

/// Machine A: no harness of its own needed, no peer link, B listed by the hub's book.
fn machine_a(mesh: Arc<dyn MeshHub>) -> Arc<Hub> {
    machine_a_seeded(mesh, &[])
}

/// Machine A with the chats `seed` (stored records, no harness started) already there.
fn machine_a_seeded(mesh: Arc<dyn MeshHub>, seed: &[Value]) -> Arc<Hub> {
    machine_a_configured(mesh, json!({}), seed)
}

/// Machine A with config `config` and the chats `seed`.
fn machine_a_configured(mesh: Arc<dyn MeshHub>, config: Value, seed: &[Value]) -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(config).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for meta in seed {
        store.save(&serde_json::from_value(meta.clone()).unwrap()).unwrap();
    }
    let a = Hub::new(config, store);
    let _ = a.mesh.set(mesh);
    a.set_mesh_book(std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]), vec![]);
    a
}

/// What the hub does to a start.
#[derive(Clone, Copy, PartialEq)]
enum HubSays {
    /// Leases it to B.
    Lease,
    /// Refuses it: the sending machine's join was revoked.
    Revoked,
}

/// The hub as both machines see it: a send is leased to B at once, under the person the hub
/// stamps (`user`), and B's ack is the receipt A reads.
struct Loopback {
    b: Arc<Hub>,
    hook: super::super::MeshControlHook,
    user: &'static str,
    says: HubSays,
    /// B runs a cmux from before marked starts: it refuses any control body but version 1, as
    /// such a daemon's `run_control` does.
    old_receiver: bool,
    receipts: Mutex<std::collections::HashMap<String, Receipt>>,
}

impl Loopback {
    /// B's `sameUser` entry, with B's recorded person `own` (None: its join was removed).
    fn new(b: &Arc<Hub>, dir: &std::path::Path, own: Option<&'static str>) -> Self {
        let hook = super::super::MeshControlHook::new(
            vec![MeshControlFrom::same_user()],
            Some(dir.join("mesh-controls.json")),
        )
        .with_own_user(Arc::new(move || own.map(str::to_owned)));
        Self {
            b: b.clone(),
            hook,
            user: "person-1",
            says: HubSays::Lease,
            old_receiver: false,
            receipts: Mutex::default(),
        }
    }
}

impl MeshHub for Loopback {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async { Ok(Vec::new()) })
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        Box::pin(async { Err(HubError::unavailable("unused")) })
    }

    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            m.validate().map_err(HubError::refused)?;
            if self.says == HubSays::Revoked {
                let mut e = HubError::refused("this machine's join was revoked");
                e.code = Some("machine.revoked".into());
                return Err(e);
            }
            if m.to.host.as_deref().is_some_and(|host| host != "machine-b") {
                let mut e = HubError::refused("no such recipient");
                e.code = Some("mesh.unknown_recipient".into());
                return Err(e);
            }
            let id = format!("msg_{}", uuid::Uuid::now_v7().simple());
            let message = InMessage {
                message_id: id.clone(),
                kind: m.kind,
                op: m.op.clone(),
                mode: m.mode,
                // The hub resolved the host: the inbox names only the session.
                to: Target {
                    session_id: m.to.session_id.clone(),
                    name: m.to.name.clone(),
                    ..Target::default()
                },
                from: Sender {
                    daemon_id: Some("inst_a".into()),
                    user: Some(self.user.into()),
                    ..m.from.clone()
                },
                body: m.body.clone(),
                attempt: 1,
                start_work: None,
                state: Some("queued".into()),
                subject: None,
            };
            let old = self.old_receiver
                && serde_json::from_str::<Value>(&m.body)
                    .ok()
                    .and_then(|body| body.get("version").and_then(Value::as_u64))
                    .is_some_and(|version| version != 1);
            let ack = if old {
                Ack::refused("unsupported control body version")
            } else {
                super::super::deliver(&self.b, &message, &self.hook, Some("inst_b"))
                    .await
                    .expect("every message is answered")
            };
            let mut receipt: Receipt = serde_json::from_value(json!({
                "messageId": id, "state": serde_json::to_value(ack.state).unwrap(), "createdAt": 1
            }))
            .unwrap();
            (receipt.prompt_id, receipt.detail, receipt.result) =
                (ack.prompt_id, ack.detail, ack.result);
            // The first receipt is still queued; the answer comes in the sender's wait.
            self.receipts.lock().unwrap().insert(id.clone(), receipt.clone());
            receipt.state = "queued".into();
            (receipt.detail, receipt.result) = (None, None);
            Ok(receipt)
        })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            self.receipts.lock().unwrap().get(id).cloned().ok_or_else(|| HubError::refused("none"))
        })
    }
}

/// One connection to a daemon, as the app's pane holds it.
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn app(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(crate::server::serve_connection_with(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::LocalApp,
        ));
        Self(in_tx, out_rx, 0)
    }

    /// The reply to `m` (its `result` or `error`); notifications before it are kept in `seen`.
    async fn call(&mut self, m: &str, params: Value, seen: &mut Vec<Value>) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(crate::rpc::Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(120), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
            seen.push(value);
        }
    }

    /// The first notification `found` takes, within 30 s.
    async fn until(&mut self, seen: &mut Vec<Value>, found: impl Fn(&Value) -> bool) -> Value {
        if let Some(hit) = seen.iter().find(|v| found(v)) {
            return hit.clone();
        }
        let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
        loop {
            let line = tokio::time::timeout_at(deadline, self.1.recv())
                .await
                .unwrap_or_else(|_| panic!("no such notification; heard {seen:?}"))
                .unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            if found(&value) {
                return value;
            }
            seen.push(value);
        }
    }
}

fn new_params(cwd: &std::path::Path, peer: &str, name: &str) -> Value {
    json!({"cwd": cwd, "mcpServers": [],
        "_meta": {"acpmux": {"harness": "fake", "name": name, "policy": "ask", "peer": peer}}})
}

/// A folder under B's root, as the person picks one on that machine.
fn project() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    let cwd = root.join("project");
    std::fs::create_dir(&cwd).unwrap();
    (dir, root, cwd)
}

#[tokio::test]
async fn a_chat_started_on_a_hub_machine_runs_there_and_its_reply_reaches_the_app() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let a = machine_a(Arc::new(Loopback::new(&b, dir.path(), Some("person-1"))));
    let mut app = Client::app(&a);
    let mut seen = Vec::new();

    let started =
        app.call("session/new", new_params(&cwd, "machine-b", "hub-chat"), &mut seen).await;
    let result = &started["result"];
    assert_eq!((result["peer"].as_str(), result["via"].as_str()), (Some("machine-b"), Some("hub")));
    let id = result["sessionId"].as_str().expect("a session id").to_owned();
    // It runs on B, under the name asked for; A has no session of its own.
    assert_eq!(b.resolve("hub-chat").unwrap().id, id);
    assert!(a.resolve(&id).is_err());
    // A lists it at once, on its machine, before the hub's book does.
    assert_eq!(a.mesh_book_host(&id).as_deref(), Some("machine-b"));

    // The app's first prompt, by the bare id the start answered: through the hub, a turn on B.
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello from a"}]});
    let sent = app.call(method::SESSION_PROMPT, prompt, &mut seen).await;
    assert_eq!(sent["result"]["via"], "mesh", "{sent}");
    // Its reply reaches this client as B's `session/update`, for the chat it opened.
    let reply = app
        .until(&mut seen, |v| {
            v["method"] == method::SESSION_UPDATE
                && v["params"]["sessionId"] == json!(id)
                && v["params"]["update"]["content"]["text"] == "echo: hello from a"
        })
        .await;
    assert_eq!(reply["params"]["peer"], "machine-b", "{reply}");

    // The book's next read without the chat keeps it; one that lists it takes it over.
    a.set_mesh_book(std::collections::BTreeMap::from([("machine-b".to_owned(), 2)]), vec![]);
    assert_eq!(a.mesh_book_host(&id).as_deref(), Some("machine-b"));
    b.shutdown_all().await;
}

#[tokio::test]
async fn a_machine_no_link_and_no_hub_lists_is_refused_by_name() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let a = machine_a(Arc::new(Loopback::new(&b, dir.path(), Some("person-1"))));
    let mut app = Client::app(&a);
    let refused =
        app.call("session/new", new_params(&cwd, "machine-c", "nowhere"), &mut Vec::new()).await;
    let error = &refused["error"];
    assert_eq!(error["code"], json!(RpcError::not_found("").code), "{refused}");
    assert!(error["message"].as_str().unwrap().contains("no peer \"machine-c\""), "{refused}");
    assert_eq!(error["data"]["reason"], "peer.unknown", "{refused}");
    assert!(b.resolve("nowhere").is_err());
    b.shutdown_all().await;
}

#[tokio::test]
async fn a_revoked_machine_starts_nothing_and_says_so() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);

    // B's join was removed: it records no person, so its `sameUser` entry grants nothing.
    let a = machine_a(Arc::new(Loopback::new(&b, dir.path(), None)));
    let refused = Client::app(&a)
        .call("session/new", new_params(&cwd, "machine-b", "revoked-there"), &mut Vec::new())
        .await;
    let error = &refused["error"];
    assert_eq!(error["data"]["reason"], "mesh.start_refused", "{refused}");
    assert!(error["message"].as_str().unwrap().contains("takes no chats"), "{refused}");
    assert!(b.resolve("revoked-there").is_err());

    // This machine's own join was revoked: the hub refuses the start.
    let mut hub = Loopback::new(&b, dir.path(), Some("person-1"));
    hub.says = HubSays::Revoked;
    let a = machine_a(Arc::new(hub));
    let refused = Client::app(&a)
        .call("session/new", new_params(&cwd, "machine-b", "revoked-here"), &mut Vec::new())
        .await;
    let error = &refused["error"];
    assert_eq!(error["data"]["reason"], "machine.revoked", "{refused}");
    assert!(error["message"].as_str().unwrap().contains("refused the chat on machine-b"));
    assert!(b.resolve("revoked-here").is_err());
    b.shutdown_all().await;
}

/// A chat started here stays listed until the book lists it, and no longer than its bound; a
/// machine the book drops takes its chats with it.
#[tokio::test]
async fn a_started_chat_is_listed_until_the_book_has_it() {
    let a = machine_a(Arc::new(Loopback::new(
        &machine_b(std::path::Path::new("/nonexistent")),
        std::path::Path::new("/nonexistent"),
        None,
    )));
    let hosts = || std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]);
    // Not a machine the book lists: nothing is kept.
    a.mesh_book_started("machine-c", "s-c", "c", "fake");
    assert_eq!(a.mesh_book_host("s-c"), None);
    a.mesh_book_started("machine-b", "s-1", "one", "fake");
    a.set_mesh_book(hosts(), vec![]);
    assert_eq!(a.mesh_book_host("s-1").as_deref(), Some("machine-b"));
    // The book lists it: one row, the book's.
    let row = crate::mesh::BookSession {
        name: "one".into(),
        session_id: "s-1".into(),
        host: "machine-b".into(),
        daemon_id: "inst_b".into(),
        harness: "fake".into(),
        state: "running".into(),
        last_seen_at: 1,
    };
    a.set_mesh_book(hosts(), vec![row]);
    assert_eq!(a.mesh_book_resolve("machine-b/one").as_deref(), Some("s-1"));
    // The book drops it again: it was the book's, so it leaves.
    a.set_mesh_book(hosts(), vec![]);
    assert_eq!(a.mesh_book_host("s-1"), None);
    // Its machine leaves the book: a pin of it goes too.
    a.mesh_book_started("machine-b", "s-2", "two", "fake");
    a.set_mesh_book(Default::default(), vec![]);
    assert_eq!(a.mesh_book_host("s-2"), None);
}

/// B's folder-trust gate, with its record in `dir`: no folder has an answer until one is set.
fn gate(b: &Arc<Hub>, dir: &std::path::Path) -> crate::trust::Paths {
    let paths = crate::trust::Paths {
        claude_json: dir.join("claude.json"),
        codex_config: dir.join("config.toml"),
        record: dir.join("trust.json"),
        agent_home: None,
        cmux_worktrees: None,
        peer_scratch: None,
    };
    b.set_trust_gate(Some(paths.clone()));
    paths
}

/// Review P1 of #38377: the pane's start through the hub is the pane's on B, as over a peer link.
/// A folder with no Trust answer refuses it (`trust.pending`) and nothing starts.
#[tokio::test]
async fn a_pane_start_through_the_hub_waits_for_the_folders_trust_answer() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let gates = tempfile::tempdir().unwrap();
    gate(&b, gates.path());
    let a = machine_a(Arc::new(Loopback::new(&b, dir.path(), Some("person-1"))));
    let refused = Client::app(&a)
        .call("session/new", new_params(&cwd, "machine-b", "untrusted"), &mut Vec::new())
        .await;
    assert_eq!(refused["error"]["data"]["reason"], "trust.pending", "{refused}");
    assert!(b.resolve("untrusted").is_err(), "a chat started in a folder with no answer");
    b.shutdown_all().await;
}

/// Review P1 of #38377: in a trusted folder the pane's chat starts and its prompt runs; once the
/// person answers Don't trust there, a prompt the hub relays to it is refused (`trust.untrusted`),
/// though the relayed prompt itself carries no mark: B holds it to the start's (`hub_via`).
#[tokio::test]
async fn a_pane_chat_started_through_the_hub_keeps_the_trust_gate_for_its_prompts() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let gates = tempfile::tempdir().unwrap();
    let paths = gate(&b, gates.path());
    crate::trust::set(&paths, cwd.to_str().unwrap(), "trusted").unwrap();
    let hub = Arc::new(Loopback::new(&b, dir.path(), Some("person-1")));
    let a = machine_a(hub.clone());
    let mut app = Client::app(&a);
    let mut seen = Vec::new();
    let started =
        app.call("session/new", new_params(&cwd, "machine-b", "trusted"), &mut seen).await;
    let id = started["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{started}"));
    let id = id.to_owned();
    let on_b = b.resolve("trusted").unwrap();
    assert_eq!(b.hub_via(&on_b).as_deref(), Some("app"), "the start's mark is not on B's chat");
    // Trusted: the prompt runs there and its reply reaches the app.
    let prompt = |text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    app.call(method::SESSION_PROMPT, prompt("first"), &mut seen).await;
    app.until(&mut seen, |v| v["params"]["update"]["content"]["text"] == "echo: first").await;
    // Don't trust: the next relayed prompt is refused on B.
    crate::trust::set(&paths, cwd.to_str().unwrap(), "untrusted").unwrap();
    let sent = app.call(method::SESSION_PROMPT, prompt("second"), &mut seen).await;
    assert!(sent.get("error").is_none(), "{sent}");
    let refusal = hub
        .receipts
        .lock()
        .unwrap()
        .values()
        .filter(|r| r.state == "refused")
        .find_map(|r| r.detail.clone())
        .unwrap_or_else(|| panic!("no relayed prompt was refused"));
    assert!(refusal.contains("trust.untrusted"), "{refusal}");
    b.shutdown_all().await;
}

/// A pane start goes through the hub only to a machine that keeps its trust gate: one on an older
/// cmux refuses the marked start's body version, nothing starts there, and the pane hears
/// `mesh.trust_unsupported` with the machine to update.
#[tokio::test]
async fn a_pane_start_to_a_machine_on_an_older_cmux_is_refused_with_update_advice() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let gates = tempfile::tempdir().unwrap();
    let paths = gate(&b, gates.path());
    crate::trust::set(&paths, cwd.to_str().unwrap(), "trusted").unwrap();
    let mut hub = Loopback::new(&b, dir.path(), Some("person-1"));
    hub.old_receiver = true;
    let a = machine_a(Arc::new(hub));
    let refused = Client::app(&a)
        .call("session/new", new_params(&cwd, "machine-b", "older"), &mut Vec::new())
        .await;
    assert_eq!(refused["error"]["data"]["reason"], "mesh.trust_unsupported", "{refused}");
    let said = refused["error"]["message"].as_str().unwrap_or_default();
    assert!(said.contains("on machine-b, choose Check for Updates"), "{said}");
    assert!(b.resolve("older").is_err(), "a chat started on a machine that cannot gate it");
    b.shutdown_all().await;
}

/// The receiver takes version 2 only for a start that carries its client's mark.
#[tokio::test]
async fn a_version_2_body_is_taken_only_for_a_marked_start() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let hook = Loopback::new(&b, dir.path(), Some("person-1")).hook;
    let send = |op: &str, body: Value| InMessage {
        message_id: format!("msg_{}", uuid::Uuid::now_v7().simple()),
        kind: crate::mesh::Kind::Control,
        op: Some(op.into()),
        mode: Default::default(),
        to: Target::default(),
        from: Sender {
            daemon_id: Some("inst_a".into()),
            user: Some("person-1".into()),
            ..Sender::default()
        },
        body: body.to_string(),
        attempt: 1,
        start_work: None,
        state: Some("queued".into()),
        subject: None,
    };
    let unmarked = json!({"version": 2, "params": {"cwd": cwd, "name": "bare"}});
    let ack = super::super::deliver(&b, &send("start", unmarked), &hook, Some("inst_b")).await;
    let detail = ack.and_then(|a| a.detail).unwrap_or_default();
    assert!(detail.contains("unsupported control body version"), "{detail}");
    assert!(b.resolve("bare").is_err());
    b.shutdown_all().await;
}

/// Review of #38377: B could not save the start's trust mark (twice), so it removes the chat and
/// refuses the start, rather than keep a chat whose relayed prompts would pass ungated after a
/// restart.
#[tokio::test]
async fn a_start_whose_trust_mark_cannot_be_saved_is_refused_and_leaves_no_chat() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let gates = tempfile::tempdir().unwrap();
    let paths = gate(&b, gates.path());
    crate::trust::set(&paths, cwd.to_str().unwrap(), "trusted").unwrap();
    crate::hub::FAIL_HUB_VIA_SAVES.lock().unwrap().push("unsaved".into());
    let a = machine_a(Arc::new(Loopback::new(&b, dir.path(), Some("person-1"))));
    let refused = Client::app(&a)
        .call("session/new", new_params(&cwd, "machine-b", "unsaved"), &mut Vec::new())
        .await;
    assert_eq!(refused["error"]["data"]["reason"], "mesh.start_unsaved", "{refused}");
    assert!(b.resolve("unsaved").is_err(), "the chat whose mark was not saved is still there");
    b.shutdown_all().await;
}

/// A message the hub leases to B from machine A's person.
fn from_a(kind: crate::mesh::Kind, op: Option<&str>, to: Target, body: String) -> InMessage {
    InMessage {
        message_id: format!("msg_{}", uuid::Uuid::now_v7().simple()),
        kind,
        op: op.map(str::to_owned),
        mode: Default::default(),
        to,
        from: Sender {
            daemon_id: Some("inst_a".into()),
            user: Some("person-1".into()),
            ..Sender::default()
        },
        body,
        attempt: 1,
        start_work: None,
        state: Some("queued".into()),
        subject: None,
    }
}

/// A store folder must be the user's alone (`config::validate_private_state_ancestors`); a temp
/// folder follows the caller's umask, group-writable under a lane VM's 002.
fn owner_only(dir: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
}

/// A temp folder a store may live under.
fn private_dir() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    owner_only(dir.path());
    dir
}

/// Copies the store folder `from` to `to` as it is on disk now: what a crash leaves.
fn crash_image(from: &std::path::Path, to: &std::path::Path) {
    std::fs::create_dir_all(to).unwrap();
    owner_only(to);
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let (path, kind) = (entry.path(), entry.file_type().unwrap());
        let target = to.join(entry.file_name());
        if kind.is_dir() {
            crash_image(&path, &target);
        } else if kind.is_file() {
            // A file removed under the copy is one the crash did not leave.
            let _ = std::fs::copy(&path, &target);
        }
    }
}

/// Review F1 of #38377: B crashes while a hub start's harness is still starting, after the chat
/// was published and saved and before `session/new` returned. The chat it restores keeps the
/// start's trust mark, so once the person answers Don't trust a prompt the hub relays to it is
/// refused (`trust.untrusted`) rather than passing the folder-trust gate.
#[tokio::test]
async fn a_hub_start_that_crashes_before_its_harness_starts_restores_with_its_trust_mark() {
    let (dir, root, cwd) = project();
    let disk = private_dir();
    // Its record reaches `session.json` within a tenth of a second, not the daemon's 30 s.
    crate::store::checkpoint_every_for_tests(disk.path(), 100);
    // Its harness never answers `initialize`: the start stays inside `session/new`.
    let b = machine_b_with(&root, Some(disk.path()), &["sleep", "120"]);
    let gates = tempfile::tempdir().unwrap();
    let paths = gate(&b, gates.path());
    crate::trust::set(&paths, cwd.to_str().unwrap(), "trusted").unwrap();
    let hook = Arc::new(Loopback::new(&b, dir.path(), Some("person-1")).hook);
    let body = json!({"version": 2, "params": {"cwd": cwd, "mcpServers": [],
        "_meta": {"acpmux": {"harness": "fake", "name": "crashed", "via": "app"}}}});
    let start =
        from_a(crate::mesh::Kind::Control, Some("start"), Target::default(), body.to_string());
    let starting = tokio::spawn({
        let (b, hook) = (b.clone(), hook.clone());
        async move { super::super::deliver(&b, &start, &*hook, Some("inst_b")).await }
    });
    // The crash: the store as it is once the chat's `session.json` is written (its journal record
    // names the folder it was made in, so only the checkpointed file survives a copy), the start
    // still running.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    let id = loop {
        assert!(tokio::time::Instant::now() < deadline, "the started chat never reached the disk");
        tokio::time::sleep(Duration::from_millis(50)).await;
        let Ok(id) = b.resolve("crashed").map(|s| s.id.clone()) else { continue };
        if disk.path().join("sessions").join(&id).join("session.json").exists() {
            break id;
        }
    };
    let image = private_dir();
    let copy = image.path().join("store");
    crash_image(disk.path(), &copy);
    assert!(!starting.is_finished(), "the start ended before the crash");
    let restored = machine_b_with(&root, Some(&copy), &["python3", FAKE]);
    restored.load_store_async().await;
    let chat = restored.resolve(&id).expect("the crashed start's chat was not restored");
    assert_eq!(
        restored.hub_via(&chat).as_deref(),
        Some("app"),
        "the chat restored from a crash during its start lost the start's trust mark"
    );
    let paths = gate(&restored, gates.path());
    crate::trust::set(&paths, cwd.to_str().unwrap(), "untrusted").unwrap();
    let to = Target { session_id: Some(id.clone()), ..Target::default() };
    let prompt = from_a(crate::mesh::Kind::Prompt, None, to, "after the crash".into());
    let restored_hook = Loopback::new(&restored, dir.path(), Some("person-1")).hook;
    let ack = super::super::deliver(&restored, &prompt, &restored_hook, Some("inst_b"))
        .await
        .expect("the relayed prompt is answered");
    let detail = ack.detail.unwrap_or_default();
    assert!(detail.contains("trust.untrusted"), "a relayed prompt passed the trust gate: {detail}");
    starting.abort();
    restored.shutdown_all().await;
    b.shutdown_all().await;
}

/// Review P2-F1 of #38377 at 60d15eda: an agent on A whose last turn a remote device drove starts a
/// chat through the hub from its own unix socket. Its start is a Web client's, but it would leave
/// A with no Web mark and B would skip the folder-trust gate; so A refuses it, as it refuses that
/// caller's mesh controls (`mesh.local_only`), and nothing starts on B.
#[tokio::test]
async fn a_hub_start_by_an_agent_a_remote_device_drives_is_refused() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    // B gates a marked start's folder; this one has no Trust answer.
    let gates = tempfile::tempdir().unwrap();
    gate(&b, gates.path());
    let (agent_id, seed) = agent_record(&cwd);
    let a = machine_a_seeded(Arc::new(Loopback::new(&b, dir.path(), Some("person-1"))), &[seed]);
    let agent = a.resolve(&agent_id).expect("the agent's chat on A");
    agent.mark_last_turn_web_for_tests();
    let mut socket = Client::agent(&a, &agent_id).await;
    let refused =
        socket.call("session/new", new_params(&cwd, "machine-b", "driven"), &mut Vec::new()).await;
    assert!(b.resolve("driven").is_err(), "a remote-driven agent's start ran on B unmarked");
    assert_eq!(refused["error"]["data"]["reason"], "mesh.local_only", "{refused}");
    a.shutdown_all().await;
    b.shutdown_all().await;
}

/// An agent's chat record on A in `cwd` (no harness started): its id and the record.
fn agent_record(cwd: &std::path::Path) -> (String, Value) {
    let id = uuid::Uuid::now_v7().to_string();
    let record = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "agent", "harness": "fake",
        "cwd": cwd, "status": "idle", "createdAt": 1, "updatedAt": 1
    });
    (id, record)
}

impl Client {
    /// A connection on `hub`'s unix socket that proved it runs in chat `id` (`callerSession`).
    async fn agent(hub: &Arc<Hub>, id: &str) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(crate::server::serve_connection_with(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::Local,
        ));
        let mut socket = Self(in_tx, out_rx, 0);
        let token = crate::hub::person::caller_token(id);
        let hello = json!({"protocolVersion": 1, "clientCapabilities": {}, "_meta": {"acpmux": {
            "callerSession": {"sessionId": id, "token": token}
        }}});
        let proven = socket.call("initialize", hello, &mut Vec::new()).await;
        assert_eq!(proven["result"]["_meta"]["acpmux"]["callerSessionId"], json!(id), "{proven}");
        socket
    }
}

/// Review P1 of #38377 at 5a5c988d: an agent on A starts a chat through the hub from a no-prompt
/// preset the person never approved. As over a linked peer (`unattended_presets.rs`), A refuses it
/// and asks for the approval (`preset.approval_required`), and nothing goes to the hub: the
/// preset's name never reaches a machine that may have a preset of that name.
#[tokio::test]
async fn a_hub_start_from_an_unapproved_no_prompt_preset_is_refused_before_it_is_sent() {
    let (_dir, _root, cwd) = project();
    let mesh = Arc::new(Recorder::default());
    let (agent_id, seed) = agent_record(&cwd);
    let config = json!({"presets": {"night": {"harness": "claude", "policy": "approve-all"}}});
    let a = machine_a_configured(mesh.clone(), config, &[seed]);
    let mut socket = Client::agent(&a, &agent_id).await;
    let params = json!({"cwd": cwd, "mcpServers": [],
        "_meta": {"acpmux": {"preset": "night", "name": "unattended", "peer": "machine-b"}}});
    let refused = socket.call("session/new", params, &mut Vec::new()).await;
    let sent = mesh.0.lock().unwrap().clone();
    assert!(sent.is_empty(), "the unapproved preset's start went to the hub: {sent:?}");
    assert_eq!(refused["error"]["data"]["reason"], "preset.approval_required", "{refused}");
    a.shutdown_all().await;
}

/// Review P2 of #38377 at 5a5c988d: a version 2 start is one that carries a mark this machine
/// gates by. With `via` null, or a value no client is, B refuses the body (as a daemon from before
/// marked starts does) and starts nothing unmarked.
#[tokio::test]
async fn a_version_2_start_with_no_valid_mark_is_refused() {
    let (dir, root, cwd) = project();
    let b = machine_b(&root);
    let hook = Loopback::new(&b, dir.path(), Some("person-1")).hook;
    for (name, via) in [("null-mark", Value::Null), ("bogus-mark", json!("bogus"))] {
        let body = json!({"version": 2, "params": {"cwd": cwd, "mcpServers": [],
            "_meta": {"acpmux": {"harness": "fake", "name": name, "via": via}}}});
        let start =
            from_a(crate::mesh::Kind::Control, Some("start"), Target::default(), body.to_string());
        let ack = super::super::deliver(&b, &start, &hook, Some("inst_b")).await;
        let detail = ack.and_then(|a| a.detail).unwrap_or_default();
        assert!(b.resolve(name).is_err(), "{name}: a version 2 start with no valid mark ran");
        assert!(detail.contains("unsupported control body version"), "{name}: {detail}");
    }
    b.shutdown_all().await;
}

/// Machine B served over a real peer link as `box` to `a`: B's server task and the folder its peer
/// key lives in (kept until the test ends).
async fn linked_b(
    a: &Arc<Hub>,
    b: &Arc<Hub>,
) -> (tokio::task::JoinHandle<anyhow::Result<()>>, tempfile::TempDir) {
    let home = private_dir();
    let auth = Arc::new(crate::server::peer_auth::PeerAuth::create(home.path()).unwrap());
    let peer_token = std::fs::read_to_string(auth.path()).unwrap();
    let listener = crate::server::bind_ws("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}", listener.local_addr().unwrap());
    let served = tokio::spawn(crate::server::serve_ws_with(
        b.clone(),
        listener,
        "start-test-token".into(),
        crate::server::WsAuth { local_app: None, peer: Some(auth) },
    ));
    a.add_peer("box", &url, Some("start-test-token".into()), Some(peer_token.trim().into()), true)
        .await
        .unwrap();
    (served, home)
}

/// The coordinator's ruling on #38377 at af6b6ea8: the linked-peer start takes the same caller
/// check as a hub start (`forwarded_start`). An agent whose last turn a remote device drove,
/// starting from A's unix socket, is refused (`mesh.local_only`) and nothing starts on the peer.
#[tokio::test]
async fn a_linked_peer_start_by_an_agent_a_remote_device_drives_is_refused() {
    let (_dir, root, cwd) = project();
    let b = machine_b(&root);
    let gates = tempfile::tempdir().unwrap();
    gate(&b, gates.path());
    let (agent_id, seed) = agent_record(&cwd);
    let a = machine_a_seeded(Arc::new(Recorder::default()), &[seed]);
    let (served, _home) = linked_b(&a, &b).await;
    a.resolve(&agent_id).expect("the agent's chat on A").mark_last_turn_web_for_tests();
    let mut socket = Client::agent(&a, &agent_id).await;
    let refused =
        socket.call("session/new", new_params(&cwd, "box", "driven-peer"), &mut Vec::new()).await;
    assert!(b.resolve("driven-peer").is_err(), "a remote-driven agent's start ran on the peer");
    assert_eq!(refused["error"]["data"]["reason"], "mesh.local_only", "{refused}");
    a.peer_by_name("box").unwrap().stop();
    served.abort();
    a.shutdown_all().await;
    b.shutdown_all().await;
}

/// The app's own start onto a linked peer has no proven caller: the caller check leaves it alone,
/// and it goes marked (`via: app`), so the peer holds it to its folder-trust gate: a folder with no
/// Trust answer there refuses it (`trust.pending`).
#[tokio::test]
async fn an_app_start_onto_a_linked_peer_still_goes_marked() {
    let (_dir, root, cwd) = project();
    let b = machine_b(&root);
    let gates = tempfile::tempdir().unwrap();
    gate(&b, gates.path());
    let a = machine_a(Arc::new(Recorder::default()));
    let (served, _home) = linked_b(&a, &b).await;
    let refused = Client::app(&a)
        .call("session/new", new_params(&cwd, "box", "app-peer"), &mut Vec::new())
        .await;
    assert_eq!(refused["error"]["data"]["reason"], "trust.pending", "{refused}");
    assert!(b.resolve("app-peer").is_err(), "the app's start ran on the peer unmarked");
    a.peer_by_name("box").unwrap().stop();
    served.abort();
    a.shutdown_all().await;
    b.shutdown_all().await;
}

/// The hub as a start sees it: keeps each `start` body it is sent and refuses it, so the start
/// ends there and the body is what the machine would have run.
#[derive(Default)]
struct Recorder(Mutex<Vec<Value>>);

impl MeshHub for Recorder {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async { Ok(Vec::new()) })
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Ok(()) })
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a crate::mesh::Heartbeat,
    ) -> BoxFuture<'a, Result<crate::mesh::HeartbeatReply, HubError>> {
        Box::pin(async { Err(HubError::unavailable("unused")) })
    }

    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            self.0.lock().unwrap().push(serde_json::from_str(&m.body).unwrap());
            Err(HubError::refused("recorded"))
        })
    }

    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { Err(HubError::refused("none")) })
    }
}

/// The app's new chat on a machine only the hub reaches starts at the person's own start level,
/// as one through an ssh peer or `acpmux session start --machine` does: full access goes as
/// approve-all, `standard` and `ask` go with no policy (the machine starts it asking), and a start
/// that names its own policy or a mode keeps it.
#[tokio::test]
async fn a_hub_machine_start_carries_the_persons_start_level() {
    // The folder the person picks: the pane's start needs one that exists.
    let (_dir, _root, cwd) = project();
    for (level, want) in
        [("fullAccess", json!("approve-all")), ("standard", Value::Null), ("ask", Value::Null)]
    {
        let mut config: Config =
            serde_json::from_value(json!({"defaultPermissionMode": level})).unwrap();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let a = Hub::new(config, store);
        let mesh = Arc::new(Recorder::default());
        let _ = a.mesh.set(mesh.clone());
        a.set_mesh_book(std::collections::BTreeMap::from([("machine-b".to_owned(), 1)]), vec![]);
        let mut app = Client::app(&a);
        for (key, meta, want) in [
            ("plain", json!({"harness": "claude"}), want.clone()),
            ("named", json!({"harness": "claude", "policy": "ask"}), json!("ask")),
            ("mode", json!({"harness": "claude", "mode": "default"}), Value::Null),
        ] {
            let mut meta = meta;
            meta["peer"] = json!("machine-b");
            meta["name"] = json!(format!("{level}-{key}"));
            let params = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": meta}});
            let reply = app.call("session/new", params, &mut Vec::new()).await;
            assert!(reply.get("error").is_some(), "{level} {key}: {reply}");
            let sent = mesh.0.lock().unwrap().pop();
            let body = sent.unwrap_or_else(|| panic!("{level} {key}: no start was sent: {reply}"));
            assert_eq!(body["params"]["_meta"]["acpmux"]["policy"], want, "{level} {key}: {body}");
        }
    }
}
