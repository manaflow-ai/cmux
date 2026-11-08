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
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    config.web_roots = vec![root.to_string_lossy().into_owned()];
    config.web_asking_modes.insert("fake".into(), vec!["normal".into(), "strict".into()]);
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

/// Machine A: no harness of its own needed, no peer link, B listed by the hub's book.
fn machine_a(mesh: Arc<dyn MeshHub>) -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
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
            let ack = super::super::deliver(&self.b, &message, &self.hook, Some("inst_b"))
                .await
                .expect("every message is answered");
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
            let line =
                tokio::time::timeout(Duration::from_secs(120), self.1.recv()).await.unwrap().unwrap();
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
    assert_eq!(a.mesh_book_resolve("one").as_deref(), Some("s-1"));
    // The book drops it again: it was the book's, so it leaves.
    a.set_mesh_book(hosts(), vec![]);
    assert_eq!(a.mesh_book_host("s-1"), None);
    // Its machine leaves the book: a pin of it goes too.
    a.mesh_book_started("machine-b", "s-2", "two", "fake");
    a.set_mesh_book(Default::default(), vec![]);
    assert_eq!(a.mesh_book_host("s-2"), None);
}
