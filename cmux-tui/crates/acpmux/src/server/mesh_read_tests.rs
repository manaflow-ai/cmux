//! A read through the hub, end to end in one process: machine A's [`read`] posts to a stand-in
//! hub that leases the message straight to machine B's relay (`deliver`, with the `sameUser`
//! control entry `host join` writes), and A reads B's reply from the receipt. No ssh peer, no
//! peer link.

use super::*;
use crate::config::Config;
use crate::mesh::{HubError, InMessage, MeshHub, Receipt};
use crate::mesh_http::MeshControlFrom;
use futures::future::BoxFuture;
use std::sync::Mutex;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn machine_b() -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

/// A local client of machine B, to make its session and run a turn.
async fn call(hub: &Arc<Hub>, m: &str, params: Value) -> Value {
    let (tx, in_rx) = mpsc::channel(16);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(crate::server::serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    tx.send(crate::rpc::Message::request(1, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv()).await.unwrap().unwrap();
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("id") == Some(&json!(1)) {
            assert!(value.get("error").is_none(), "{value}");
            return value["result"].clone();
        }
    }
}

/// The hub as both machines see it: a send is leased to B at once, under the person the hub
/// stamps (`user`), and B's ack is the receipt A reads.
struct Loopback {
    b: Arc<Hub>,
    hook: super::super::MeshControlHook,
    user: &'static str,
    receipts: Mutex<std::collections::HashMap<String, Receipt>>,
    unknown: bool,
}

impl Loopback {
    fn new(b: &Arc<Hub>, dir: &std::path::Path, user: &'static str) -> Self {
        let hook = super::super::MeshControlHook::new(
            vec![MeshControlFrom::same_user()],
            Some(dir.join("mesh-controls.json")),
        )
        .with_own_user(Arc::new(|| Some("person-1".to_owned())));
        Self { b: b.clone(), hook, user, receipts: Mutex::default(), unknown: false }
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
            if self.unknown {
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
                .expect("a read is always answered");
            let mut receipt: Receipt = serde_json::from_value(json!({
                "messageId": id, "state": serde_json::to_value(ack.state).unwrap(), "createdAt": 1
            }))
            .unwrap();
            (receipt.detail, receipt.result) = (ack.detail, ack.result);
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

#[test]
fn a_key_names_a_session_id_or_a_name_on_its_host() {
    let id = "019a5d1e-8f00-7000-8000-000000000001";
    let by_id = recipient("machine-b", id);
    assert_eq!((by_id.session_id.as_deref(), by_id.name), (Some(id), None));
    let by_name = recipient("machine-b", "own-e2e");
    assert_eq!(
        (by_name.name.as_deref(), by_name.host.as_deref()),
        (Some("own-e2e"), Some("machine-b"))
    );
    // Only the params a read takes go across, never a session or host the asker names.
    let sent: Value = serde_json::from_str(&body(
        method::MUX_EVENTS,
        &json!({"sessionId": "x", "host": "y", "limit": 5, "maxBytes": 9, "kinds": ["transcript"]}),
    ))
    .unwrap();
    assert_eq!(sent["params"], json!({"limit": 5, "maxBytes": 9, "kinds": ["transcript"]}));
    assert_eq!(
        serde_json::from_str::<Value>(&body(method::MUX_INFO, &json!({"x": 1}))).unwrap()["params"],
        json!({})
    );
}

#[tokio::test]
async fn the_same_persons_machine_reads_a_reply_through_the_hub_and_no_one_else_does() {
    let b = machine_b();
    let meta = json!({"acpmux": {"harness": "fake", "name": "own-e2e"}});
    let made = call(
        &b,
        "session/new",
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await;
    let session = made["sessionId"].as_str().unwrap().to_owned();
    call(
        &b,
        method::SESSION_PROMPT,
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "pong from b"}]}),
    )
    .await;
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");

    // `acpmux last machine-b/own-e2e`: info names the session, then its events page.
    let info = read(&hub, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap();
    assert_eq!(
        (info["sessionId"].as_str(), info["peer"].as_str()),
        (Some(session.as_str()), Some("machine-b"))
    );
    assert_eq!(info["via"], "hub");
    let page =
        json!({"limit": 5000, "kinds": ["transcript"], "maxBytes": 4 << 20, "beforeSeq": u64::MAX});
    let events = read(&hub, "machine-b", &session, method::MUX_EVENTS, &page).await.unwrap();
    let mut transcript = crate::transcript::Transcript::default();
    for event in events["events"].as_array().unwrap() {
        transcript.apply_event(event);
    }
    let replies: Vec<_> = transcript
        .items
        .iter()
        .filter_map(|item| match item {
            crate::transcript::Item::Assistant { text } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(replies, ["echo: pong from b"]);

    // The app's open of the chat: a hidden attach there, answered with its detail and newest page.
    let attach =
        json!({"sessionId": format!("machine-b/{session}"), "limit": 200, "maxBytes": 1 << 20});
    let opened = read(&hub, "machine-b", &session, method::MUX_ATTACH, &attach).await.unwrap();
    assert_eq!(opened["session"]["sessionId"].as_str(), Some(session.as_str()), "{opened}");
    assert!(opened["events"].as_array().is_some_and(|events| !events.is_empty()), "{opened}");
    assert_eq!(opened["peer"], "machine-b");

    // Another person is refused by B itself, whatever the hub let through.
    let other = Loopback::new(&b, dir.path(), "person-2");
    let refused =
        read(&other, "machine-b", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert!(refused.message.contains("mesh.control_not_allowed"), "{refused:?}");
    // A session B does not have, or one the hub does not know, is `no session`.
    let missing =
        read(&hub, "machine-b", "nobody", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert_eq!(missing.code, RpcError::not_found("").code, "{missing:?}");
    let unknown = Loopback { unknown: true, ..Loopback::new(&b, dir.path(), "person-1") };
    let unknown =
        read(&unknown, "machine-c", "own-e2e", method::MUX_INFO, &json!({})).await.unwrap_err();
    assert_eq!(unknown.code, RpcError::not_found("").code, "{unknown:?}");
}

#[tokio::test]
async fn a_read_runs_only_a_read_method() {
    let b = machine_b();
    let dir = tempfile::tempdir().unwrap();
    let hub = Loopback::new(&b, dir.path(), "person-1");
    let refused =
        read(&hub, "machine-b", "own-e2e", method::SESSION_PROMPT, &json!({})).await.unwrap_err();
    assert!(refused.message.contains("mesh.read_unsupported"), "{refused:?}");
}
