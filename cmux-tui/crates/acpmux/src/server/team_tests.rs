//! Team RPC authorization and receipts through the actual daemon dispatcher.

use super::*;
use crate::config::{Config, StoreMode};
use crate::mesh::{Ack, Heartbeat, HeartbeatReply, HubError, InMessage, Receipt, TeamPage};
use futures::future::BoxFuture;
use std::sync::Mutex;
use std::time::Duration;
use tokio::sync::mpsc;

const OWN: &str = "team-reader";
const OTHER: &str = "team-other";
const OWN_MESSAGE: &str = "msg_00000000000000000000000000000001";
const OTHER_MESSAGE: &str = "msg_00000000000000000000000000000002";

fn message(id: &str, session: &str) -> InMessage {
    serde_json::from_value(json!({
        "messageId": id, "kind": "prompt", "body": "Status ready\nFull message body",
        "to": {"sessionId": session, "teamAddress": "@member/coordinator"},
        "from": {"teamAddress": "@teammate/reviewer"},
        "startWork": "information", "state": "delivered"
    }))
    .unwrap()
}

fn receipt(id: &str, state: &str) -> Receipt {
    serde_json::from_value(json!({
        "messageId": id, "state": state,
        "to": {"sessionId": if id == OWN_MESSAGE { OWN } else { OTHER },
            "teamAddress": "@member/coordinator"},
        "startWork": "information", "readAt": 123, "readBy": "hub-user",
        "ackedAt": if state == "acked" { Some(456) } else { None::<u64> }
    }))
    .unwrap()
}

#[derive(Default)]
struct FakeHub {
    sent: Mutex<Vec<OutMessage>>,
    browsed: Mutex<Vec<(bool, Option<String>, Option<u64>)>>,
    reads: Mutex<Vec<String>>,
    acknowledgements: Mutex<Vec<String>>,
    session_only_receipt: std::sync::atomic::AtomicBool,
    omit_start_work: std::sync::atomic::AtomicBool,
}

impl MeshHub for FakeHub {
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        panic!("browsing must never acquire a relay lease")
    }

    fn team_messages<'a>(
        &'a self,
        unread: bool,
        address: Option<&'a str>,
        before: Option<u64>,
    ) -> BoxFuture<'a, Result<TeamPage, HubError>> {
        self.browsed.lock().unwrap().push((unread, address.map(str::to_owned), before));
        Box::pin(async {
            Ok(TeamPage {
                messages: vec![message(OWN_MESSAGE, OWN), message(OTHER_MESSAGE, OTHER)],
                next: None,
            })
        })
    }

    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        panic!("these requests do not heartbeat")
    }

    fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.sent.lock().unwrap().push(message.clone());
        Box::pin(async { Ok(receipt(OWN_MESSAGE, "queued")) })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            let mut receipt = receipt(id, "delivered");
            if self.session_only_receipt.load(std::sync::atomic::Ordering::SeqCst) {
                receipt.to.team_address = None;
            }
            if self.omit_start_work.load(std::sync::atomic::Ordering::SeqCst) {
                receipt.start_work = None;
            }
            Ok(receipt)
        })
    }

    fn read<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.reads.lock().unwrap().push(id.to_owned());
        Box::pin(async move { Ok(receipt(id, "read")) })
    }

    fn acknowledge<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.acknowledgements.lock().unwrap().push(id.to_owned());
        Box::pin(async move { Ok(receipt(id, "acked")) })
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        panic!("recipient acknowledgement must not send a delivery ack")
    }
}

fn setup(enabled: bool) -> (Arc<Hub>, Arc<FakeHub>) {
    let mut config: Config = serde_json::from_value(json!({"meshRelay": {
        "url": "https://hub.invalid", "tokenCommand": ["unused"], "teamMessaging": enabled
    }}))
    .unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for id in [OWN, OTHER] {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
            "tags": {"teamAddress": {"value": "coordinator"}}
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    let hub = Hub::new(config, store);
    assert!(hub.resolve(OWN).is_ok());
    let fake = Arc::new(FakeHub::default());
    assert!(hub.mesh.set(fake.clone()).is_ok());
    (hub, fake)
}

struct Rpc(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Rpc {
    async fn connect(hub: &Arc<Hub>, origin: Origin, caller: Option<(&str, bool)>) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (output, outgoing) = mpsc::channel(64);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
        let mut client = Self(input, outgoing, 0);
        let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
        if let Some((id, valid)) = caller {
            hello["_meta"] = json!({"acpmux": {"callerSession": {"sessionId": id,
                "token": if valid { crate::hub::person::caller_token(id) } else { "invalid".into() }
            }}});
        }
        let result = client.call("initialize", hello).await;
        assert!(result.get("error").is_none(), "{result}");
        client
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let response: Value = serde_json::from_str(&self.1.recv().await.unwrap()).unwrap();
                if response["id"] == id {
                    return response;
                }
            }
        })
        .await
        .unwrap()
    }
}

#[tokio::test]
async fn team_send_checks_labs_and_uses_proven_sender_without_start_work() {
    let (off, fake) = setup(false);
    let mut caller = Rpc::connect(&off, Origin::Local, Some((OWN, true))).await;
    let refused =
        caller.call(method::MUX_TEAM_SEND, json!({"to": "@team/reviewer", "body": "hi"})).await;
    assert_eq!(refused["error"]["data"]["reason"], "team_messaging_disabled", "{refused}");
    assert!(fake.sent.lock().unwrap().is_empty());

    let (hub, fake) = setup(true);
    let mut caller = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let sent = caller
        .call(
            method::MUX_TEAM_SEND,
            json!({
                "to": "@team/reviewer", "body": "  status\n", "startWork": "allowed",
                "from": {"teamAddress": "@owner/coordinator", "sessionId": OTHER, "user": "forged"}
            }),
        )
        .await;
    assert_eq!(sent["result"]["startWork"], "information", "{sent}");
    let messages = fake.sent.lock().unwrap();
    assert_eq!(messages.len(), 1);
    let wire = serde_json::to_value(&messages[0]).unwrap();
    assert_eq!(wire["to"], json!({"teamAddress": "@team/reviewer"}));
    assert_eq!(wire["body"], "  status\n");
    assert!(wire.get("startWork").is_none());
    assert_eq!(wire["mode"], "turn-end");
    assert_eq!(wire["from"]["sessionId"], OWN);
    assert_eq!(wire["from"]["name"], OWN);
    assert!(wire["from"].get("user").is_none());
    assert!(
        wire["from"].get("teamAddress").is_none(),
        "the hub derives the canonical sender from the proven session id"
    );
}

#[tokio::test]
async fn team_reader_is_scoped_to_session_and_read_ack_preserve_hub_receipts() {
    let (hub, fake) = setup(true);
    let mut caller = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let inbox = caller
        .call(
            method::MUX_TEAM_INBOX,
            json!({"teamAddress": "@other/coordinator", "unreadOnly": false}),
        )
        .await;
    let rows = inbox["result"]["messages"].as_array().unwrap();
    assert_eq!(rows.len(), 1, "{inbox}");
    assert_eq!(rows[0]["messageId"], OWN_MESSAGE);
    assert_eq!(fake.browsed.lock().unwrap()[0], (false, None, None));
    for method in [method::MUX_TEAM_READ, method::MUX_TEAM_ACK] {
        let refused = caller.call(method, json!({"id": OTHER_MESSAGE})).await;
        assert_eq!(refused["error"]["data"]["reason"], "team.forbidden", "{refused}");
    }
    assert!(fake.reads.lock().unwrap().is_empty());
    assert!(fake.acknowledgements.lock().unwrap().is_empty());
    let read = caller.call(method::MUX_TEAM_READ, json!({"id": OWN_MESSAGE})).await;
    assert_eq!(read["result"]["message"]["body"], "Status ready\nFull message body");
    assert_eq!(read["result"]["message"]["state"], "read");
    assert_eq!(
        read["result"]["receipt"],
        serde_json::to_value(receipt(OWN_MESSAGE, "read")).unwrap()
    );
    let acked = caller.call(method::MUX_TEAM_ACK, json!({"id": OWN_MESSAGE})).await;
    assert_eq!(acked["result"], serde_json::to_value(receipt(OWN_MESSAGE, "acked")).unwrap());
    assert_eq!(*fake.reads.lock().unwrap(), vec![OWN_MESSAGE.to_owned()]);
    assert_eq!(*fake.acknowledgements.lock().unwrap(), vec![OWN_MESSAGE.to_owned()]);
}

#[tokio::test]
async fn owner_can_browse_all_but_invalid_callers_and_remote_connections_cannot() {
    let (hub, fake) = setup(true);
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    let listed = owner.call(method::MUX_TEAM_INBOX, json!({})).await;
    assert_eq!(listed["result"]["messages"].as_array().unwrap().len(), 2);
    let read = owner.call(method::MUX_TEAM_READ, json!({"id": OTHER_MESSAGE})).await;
    assert_eq!(read["result"]["receipt"]["state"], "read", "{read}");
    let acked = owner.call(method::MUX_TEAM_ACK, json!({"id": OTHER_MESSAGE})).await;
    assert_eq!(acked["result"]["state"], "acked", "{acked}");
    let browsed = fake.browsed.lock().unwrap().len();
    for (origin, caller) in [(Origin::Local, Some((OWN, false))), (Origin::Peer, None)] {
        let mut denied = Rpc::connect(&hub, origin, caller).await;
        for method in [
            method::MUX_TEAM_INBOX,
            method::MUX_TEAM_READ,
            method::MUX_TEAM_ACK,
            method::MUX_TEAM_SEND,
        ] {
            let reply = denied
                .call(method, json!({"id": OWN_MESSAGE, "to": "@team/reviewer", "body": "hi"}))
                .await;
            assert!(reply.get("error").is_some(), "{method}: {reply}");
        }
    }
    assert_eq!(fake.browsed.lock().unwrap().len(), browsed);
    assert!(fake.sent.lock().unwrap().is_empty());
    assert_eq!(*fake.reads.lock().unwrap(), vec![OTHER_MESSAGE.to_owned()]);
    assert_eq!(*fake.acknowledgements.lock().unwrap(), vec![OTHER_MESSAGE.to_owned()]);
}

#[tokio::test]
async fn team_legacy_routes_share_authorization_and_status_is_scoped() {
    let (hub, fake) = setup(true);
    let status = json!({"deliveryId": format!("mesh:{OWN_MESSAGE}")});
    for (origin, identity) in [(Origin::Peer, None), (Origin::Local, Some((OWN, false)))] {
        let mut caller = Rpc::connect(&hub, origin, identity).await;
        let reply = caller.call(method::MUX_SEND_STATUS, status.clone()).await;
        assert!(reply.get("error").is_some(), "{reply}");
        let reply = caller
            .call(
                method::MUX_SEND_QUEUE,
                json!({"request": {
                    "sessionId": "@team/reviewer", "prompt": [{"type": "text", "text": "hello"}]
                }}),
            )
            .await;
        assert!(reply.get("error").is_some(), "{reply}");
    }
    assert!(fake.sent.lock().unwrap().is_empty());
    let mut other = Rpc::connect(&hub, Origin::Local, Some((OTHER, true))).await;
    let refused = other.call(method::MUX_SEND_STATUS, status.clone()).await;
    assert_eq!(refused["error"]["data"]["reason"], "team.forbidden", "{refused}");
    // A real sender may see its outgoing receipt even when the resolved recipient differs.
    let sent =
        other.call(method::MUX_TEAM_SEND, json!({"to": "@team/reviewer", "body": "hello"})).await;
    assert!(sent.get("error").is_none(), "{sent}");
    let reply = other.call(method::MUX_SEND_STATUS, status.clone()).await;
    assert_eq!(reply["result"]["status"], "delivered", "{reply}");
    let mut recipient = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let reply = recipient.call(method::MUX_SEND_STATUS, status.clone()).await;
    assert_eq!(reply["error"]["data"]["reason"], "team.forbidden", "{reply}");
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    assert!(owner.call(method::MUX_SEND_STATUS, status.clone()).await.get("error").is_none());
    hub.config.write().await.mesh_relay.as_mut().unwrap().team_messaging = false;
    let refused = owner.call(method::MUX_SEND_STATUS, status).await;
    assert_eq!(refused["error"]["data"]["reason"], "team_messaging_disabled", "{refused}");
}

fn legacy_team_send(key: &str) -> Value {
    json!({"request": {
        "sessionId": "@team/reviewer",
        "prompt": [{"type": "text", "text": "hello"}],
        "_meta": {"acpmux": {"promptId": key, "fromAgent": OWN, "resend": true}}
    }})
}

#[tokio::test]
async fn retry_keys_are_stable_per_proven_sender_and_shared_by_both_send_routes() {
    let (hub, fake) = setup(true);
    // Include keys the legacy mesh route would otherwise normalize differently.
    for key in ["same-retry-key", "x", "retry with spaces"] {
        let mut sender_keys = Vec::new();
        for identity in [Some((OWN, true)), Some((OTHER, true)), None] {
            let start = fake.sent.lock().unwrap().len();
            let mut first = Rpc::connect(&hub, Origin::Local, identity).await;
            let sent = first
                .call(
                    method::MUX_TEAM_SEND,
                    json!({
                        "to": "@team/reviewer", "body": "hello", "idempotencyKey": key,
                        "from": {"sessionId": OWN}, "sender": OWN
                    }),
                )
                .await;
            assert!(sent.get("error").is_none(), "{sent}");
            // Retry on a fresh authenticated connection: connection ids must not
            // change the namespace, and the legacy path must use the same key.
            let mut reconnected = Rpc::connect(&hub, Origin::Local, identity).await;
            let again = reconnected
                .call(
                    method::MUX_TEAM_SEND,
                    json!({
                        "to": "@team/reviewer", "body": "hello", "idempotencyKey": key
                    }),
                )
                .await;
            assert!(again.get("error").is_none(), "{again}");
            let legacy = reconnected.call(method::MUX_SEND_QUEUE, legacy_team_send(key)).await;
            assert!(legacy.get("error").is_none(), "{legacy}");
            let sent = fake.sent.lock().unwrap();
            assert_eq!(sent.len(), start + 3);
            assert!(
                sent[start..].iter().all(|message| message.from.team_address.is_none()),
                "a bare heartbeat suffix is not a sender address"
            );
            let assigned = &sent[start].idempotency_key;
            assert_ne!(assigned, key, "a raw caller-selected key is not namespaced");
            assert_eq!(assigned, &sent[start + 1].idempotency_key);
            assert_eq!(assigned, &sent[start + 2].idempotency_key);
            sender_keys.push(assigned.clone());
        }
        assert_eq!(
            sender_keys.iter().collect::<std::collections::BTreeSet<_>>().len(),
            3,
            "the owner and both agent sessions must have separate retry namespaces"
        );
    }
}

#[tokio::test]
async fn legacy_team_send_records_sender_ownership_for_status_after_reconnection() {
    let (hub, fake) = setup(true);
    // The fake hub resolves to OWN; OTHER may read that receipt only after it
    // actually sends, regardless of the fromAgent hint in the request.
    let status = json!({"deliveryId": format!("mesh:{OWN_MESSAGE}")});
    let mut sender = Rpc::connect(&hub, Origin::Local, Some((OTHER, true))).await;
    let refused = sender.call(method::MUX_SEND_STATUS, status.clone()).await;
    assert_eq!(refused["error"]["data"]["reason"], "team.forbidden", "{refused}");
    let queued = sender.call(method::MUX_SEND_QUEUE, legacy_team_send("outgoing-retry")).await;
    assert_eq!(queued["result"]["deliveryId"], format!("mesh:{OWN_MESSAGE}"), "{queued}");
    {
        let sent = fake.sent.lock().unwrap();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].from.session_id.as_deref(), Some(OTHER));
    }
    drop(sender);
    let mut reconnected = Rpc::connect(&hub, Origin::Local, Some((OTHER, true))).await;
    let delivered = reconnected.call(method::MUX_SEND_STATUS, status).await;
    assert_eq!(delivered["result"]["status"], "delivered", "{delivered}");
    assert_eq!(delivered["result"]["target"], "@member/coordinator", "{delivered}");
    // Sender status ownership does not grant recipient read/ack authority.
    for method in [method::MUX_TEAM_READ, method::MUX_TEAM_ACK] {
        let refused = reconnected.call(method, json!({"id": OWN_MESSAGE})).await;
        assert_eq!(refused["error"]["data"]["reason"], "team.forbidden", "{refused}");
    }
    assert!(fake.reads.lock().unwrap().is_empty());
    assert!(fake.acknowledgements.lock().unwrap().is_empty());
}

async fn resolved_team_status_is_refused(enabled: bool) {
    let (hub, fake) = setup(true);
    // The sender and recipient are OWN. OTHER must never read this receipt.
    let mut sender = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let sent = sender
        .call(
            method::MUX_TEAM_SEND,
            json!({"to": "@team/reviewer", "body": "private team message"}),
        )
        .await;
    assert!(sent.get("error").is_none(), "{sent}");
    fake.session_only_receipt.store(true, std::sync::atomic::Ordering::SeqCst);
    hub.config.write().await.mesh_relay.as_mut().unwrap().team_messaging = enabled;
    let mut unrelated = Rpc::connect(&hub, Origin::Local, Some((OTHER, true))).await;
    let reply = unrelated
        .call(method::MUX_SEND_STATUS, json!({"deliveryId": format!("mesh:{OWN_MESSAGE}")}))
        .await;
    assert_eq!(
        reply["error"]["data"]["reason"],
        if enabled { "team.forbidden" } else { "team_messaging_disabled" },
        "{reply}"
    );
    if enabled {
        // A missing marker must not erase the locally recorded origin either.
        fake.omit_start_work.store(true, std::sync::atomic::Ordering::SeqCst);
        let reply = sender
            .call(method::MUX_SEND_STATUS, json!({"deliveryId": format!("mesh:{OWN_MESSAGE}")}))
            .await;
        assert_eq!(reply["result"]["target"], "@team/reviewer", "{reply}");
        fake.omit_start_work.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

#[tokio::test]
async fn resolved_team_status_refuses_unrelated_caller_with_labs_off() {
    resolved_team_status_is_refused(false).await;
}

#[tokio::test]
async fn resolved_team_status_refuses_unrelated_caller_with_labs_on() {
    resolved_team_status_is_refused(true).await;
}

#[tokio::test]
async fn team_receipt_origin_survives_restart_and_gates_owner_sends_without_wire_markers() {
    let (hub, fake) = setup(true);
    let dir = std::env::temp_dir().join(format!("team-origin-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("outbox.json");
    assert!(hub.outbox.open(&path).is_empty());
    let mut owner = Rpc::connect(&hub, Origin::Local, None).await;
    assert!(
        owner
            .call(method::MUX_TEAM_SEND, json!({"to": "@team/reviewer", "body": "owner sent"}))
            .await
            .get("error")
            .is_none()
    );
    fake.session_only_receipt.store(true, std::sync::atomic::Ordering::SeqCst);
    fake.omit_start_work.store(true, std::sync::atomic::Ordering::SeqCst);
    let (restarted, restarted_fake) = setup(true);
    assert!(restarted.outbox.open(&path).is_empty(), "receipt metadata never resumes as a prompt");
    let origin = restarted.outbox.team_receipt(OWN_MESSAGE).unwrap();
    assert_eq!(origin.target, "@team/reviewer");
    assert!(origin.caller.is_none());
    assert!(restarted.outbox.get(&format!("mesh:{OWN_MESSAGE}")).is_none());
    // Prompt retry ids are caller-controlled and must never resolve to receipt metadata.
    let delivery = restarted.outbox.add(crate::hub::outbox::Delivery {
        id: "ordinary-delivery".into(),
        target: OTHER.into(),
        request: json!({"_meta": {"acpmux": {"promptId": format!("mesh:{OWN_MESSAGE}")}}}),
        caller: Some(OTHER.into()),
        state: crate::hub::outbox::State::Delivered,
        attempts: 0,
        never_sent: false,
        relay_post: None,
        error: None,
        accepted: None,
        created_at: crate::store::now_ms(),
        updated_at: crate::store::now_ms(),
    });
    assert_eq!(delivery.id, "ordinary-delivery");
    assert_eq!(delivery.target, OTHER);
    restarted_fake.session_only_receipt.store(true, std::sync::atomic::Ordering::SeqCst);
    restarted_fake.omit_start_work.store(true, std::sync::atomic::Ordering::SeqCst);
    // The resolved OWN sessionId grants no authority: the owner sent with no caller journal.
    for id in [OWN, OTHER] {
        let mut caller = Rpc::connect(&restarted, Origin::Local, Some((id, true))).await;
        let reply = caller
            .call(method::MUX_SEND_STATUS, json!({"deliveryId": format!("mesh:{OWN_MESSAGE}")}))
            .await;
        assert_eq!(reply["error"]["data"]["reason"], "team.forbidden", "{reply}");
    }
    restarted.config.write().await.mesh_relay.as_mut().unwrap().team_messaging = false;
    let mut owner = Rpc::connect(&restarted, Origin::Local, None).await;
    let reply = owner
        .call(method::MUX_SEND_STATUS, json!({"deliveryId": format!("mesh:{OWN_MESSAGE}")}))
        .await;
    assert_eq!(reply["error"]["data"]["reason"], "team_messaging_disabled", "{reply}");
    std::fs::remove_dir_all(dir).unwrap();
}
