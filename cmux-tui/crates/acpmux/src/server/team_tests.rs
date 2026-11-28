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
    /// Failures the next browses answer, one each, before the page.
    browse_failures: Mutex<std::collections::VecDeque<HubError>>,
    /// Every mark-read try waits out the HTTP client's 30 s and then fails, as a hub that holds
    /// the request and never answers.
    stalled_reads: std::sync::atomic::AtomicBool,
    /// Every listen call, in order: `open ADDRESS TTL`, `ls`, `close ID`.
    listen_calls: Mutex<Vec<String>>,
}

const LISTEN: &str = "lsn_0123456789abcdef0123456789abcdef";

fn listens() -> crate::mesh::Listens {
    serde_json::from_value(json!({"listening": [{"id": LISTEN, "teamAddress": "@sam/coordinator",
        "listener": "me", "openedBy": "me", "openedAt": 1, "expiresAt": 2}], "listeners": []}))
    .unwrap()
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
        let failure = self.browse_failures.lock().unwrap().pop_front();
        Box::pin(async move {
            if let Some(e) = failure {
                return Err(e);
            }
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
        let stalled = self.stalled_reads.load(std::sync::atomic::Ordering::SeqCst);
        Box::pin(async move {
            if stalled {
                tokio::time::sleep(Duration::from_secs(30)).await;
                return Err(HubError::unavailable("the hub: operation timed out"));
            }
            Ok(receipt(id, "read"))
        })
    }

    fn acknowledge<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.acknowledgements.lock().unwrap().push(id.to_owned());
        Box::pin(async move { Ok(receipt(id, "acked")) })
    }

    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        panic!("recipient acknowledgement must not send a delivery ack")
    }

    fn listen_open<'a>(
        &'a self,
        address: &'a str,
        ttl: Option<u64>,
    ) -> BoxFuture<'a, Result<crate::mesh::Listen, HubError>> {
        self.listen_calls.lock().unwrap().push(format!("open {address} {ttl:?}"));
        Box::pin(async { Ok(listens().listening.remove(0)) })
    }

    fn listens(&self) -> BoxFuture<'_, Result<crate::mesh::Listens, HubError>> {
        self.listen_calls.lock().unwrap().push("ls".into());
        Box::pin(async { Ok(listens()) })
    }

    fn listen_close<'a>(
        &'a self,
        id: &'a str,
    ) -> BoxFuture<'a, Result<crate::mesh::Listens, HubError>> {
        self.listen_calls.lock().unwrap().push(format!("close {id}"));
        Box::pin(async { Ok(crate::mesh::Listens::default()) })
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
    hub.mesh.set(fake.clone());
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
        let expected =
            caller.filter(|(_, valid)| *valid && origin == Origin::Local).map(|(id, _)| id);
        assert_eq!(result["result"]["_meta"]["acpmux"]["callerSessionId"].as_str(), expected);

        client
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.call_within(method, params, Duration::from_secs(5)).await
    }

    /// [`Rpc::call`], waiting up to `wait` for the answer.
    async fn call_within(&mut self, method: &str, params: Value, wait: Duration) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        tokio::time::timeout(wait, async {
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
    let origin = restarted.outbox.mesh_origin(OWN_MESSAGE).unwrap();
    assert!(origin.team_origin(), "a team send is recorded as a team origin");
    assert_eq!(origin.target, "@team/reviewer");
    assert!(origin.caller.is_none());
    assert!(restarted.outbox.get(&format!("mesh:{OWN_MESSAGE}")).is_none());
    // Prompt retry ids are caller-controlled and must never resolve to receipt metadata.
    let delivery = restarted
        .outbox
        .add(crate::hub::outbox::Delivery {
            id: "ordinary-delivery".into(),
            target: OTHER.into(),
            request: json!({"_meta": {"acpmux": {"promptId": format!("mesh:{OWN_MESSAGE}")}}}),
            caller: Some(OTHER.into()),
            unproven_caller: None,
            not_terminal: false,
            state: crate::hub::outbox::State::Delivered,
            attempts: 0,
            never_sent: false,
            resends: 0,
            resent_at: 0,
            relay_post: None,
            relay_unreached: false,
            direct_maybe: false,
            open_on_peer: false,
            pin: None,
            proof: None,
            error: None,
            accepted: None,
            created_at: crate::store::now_ms(),
            updated_at: crate::store::now_ms(),
        })
        .unwrap();
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

#[tokio::test]
async fn cloud_repo_initialize_reports_only_the_verified_local_caller() {
    let (hub, _) = setup(false);
    for caller in [None, Some((OWN, true)), Some((OWN, false))] {
        let _client = Rpc::connect(&hub, Origin::Local, caller).await;
    }
    // A later initialize cannot replace the first connection binding.
    let mut client = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let reply = client
        .call(
            "initialize",
            json!({"_meta":{"acpmux":{"callerSession":{
                "sessionId":OTHER,"token":crate::hub::person::caller_token(OTHER)
            }}}}),
        )
        .await;
    assert_eq!(reply["result"]["_meta"]["acpmux"]["callerSessionId"], OWN);
}

/// A hub answer with `status` and `code`, as `mesh_http::answer` makes it.
fn hub_status(status: u16, code: &str) -> HubError {
    let mut e = HubError::refused(format!("the hub answered {status} {code}"));
    e.refused = !(status == 408 || status == 429 || status >= 500);
    e.status = Some(status);
    e.code = Some(code.into());
    e
}

/// `acpmux inbox` through a hub that blips once reads the page; one that keeps failing says
/// which way it failed: a hub that is down is unavailable, a dropped connection did not answer,
/// a refusal is the hub's, and a refusal this daemon made itself (no token command) is not.
#[tokio::test(start_paused = true)]
async fn an_inbox_read_tries_a_blip_again_and_names_how_it_failed() {
    let (_hub, fake) = setup(true);
    let mesh: Arc<dyn MeshHub> = fake.clone();
    fake.browse_failures.lock().unwrap().push_back(hub_status(503, "mesh.unavailable"));
    let page = team_page(&mesh, true, None).await.unwrap();
    assert_eq!(page.messages.len(), 2);
    assert_eq!(fake.browsed.lock().unwrap().len(), 2);

    let cases = [
        (hub_status(503, "mesh.unavailable"), "the mesh hub is unavailable", "mesh.unavailable"),
        (
            HubError::unavailable("the hub: error sending request"),
            "the mesh hub did not answer",
            "mesh.unavailable",
        ),
        (
            hub_status(403, "mesh.forbidden"),
            "the mesh hub refused the inbox read",
            "mesh.forbidden",
        ),
        (
            HubError::refused("no token command"),
            "this daemon could not ask the mesh hub",
            "mesh.unavailable",
        ),
    ];
    for (e, words, reason) in cases {
        *fake.browse_failures.lock().unwrap() =
            std::iter::repeat_n(e, crate::mesh_retry::ATTEMPTS).collect();
        let e = team_page(&mesh, true, None).await.unwrap_err();
        assert!(e.message.starts_with(words), "{words}: {e:?}");
        assert_eq!(e.data.unwrap()["reason"], json!(reason), "{words}");
    }
}

/// A stand-in hub over real HTTP that answers every request `status` with `body`, for as many
/// requests as come; the task ends when the test drops the handle's runtime.
async fn http_hub_answering(status: u16, body: &'static str) -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let mut bytes = Vec::new();
            while !bytes.windows(4).any(|s| s == b"\r\n\r\n") {
                let mut chunk = [0; 1024];
                match stream.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => bytes.extend_from_slice(&chunk[..n]),
                }
            }
            let answer = format!(
                "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(answer.as_bytes()).await;
        }
    });
    url
}

fn http_hub(url: &str, token_command: &[&str]) -> Arc<dyn MeshHub> {
    Arc::new(
        crate::mesh_http::HttpHub::new(&crate::mesh_http::MeshRelayConfig {
            url: url.into(),
            token_command: token_command.iter().map(|s| (*s).to_owned()).collect(),
            team_messaging: true,
            credential: None,
            control_from: Vec::new(),
            direct_send: false,
        })
        .unwrap(),
    )
}

/// Review of #49453 (follow-ups 1 and 2): `acpmux inbox` through the real HTTP client says where
/// its failure came from. An answer of the hub's with no status of its own (one not the shape of
/// the contract) is the hub's refusal, not this daemon failing to ask; a 401 is the hub's refusal
/// too; a token command that cannot run is this daemon's own; no connection is a hub that did not
/// answer. Reason and retryable stay as they were.
#[tokio::test]
async fn an_inbox_failure_says_whether_the_hub_refused_or_this_daemon_could_not_ask() {
    let mint = ["sh", "-c", "echo test-fixture-token"];
    let refusing = http_hub_answering(401, "{}").await;
    let malformed = http_hub_answering(200, r#"{"messages": 5}"#).await;
    let cases = [
        (http_hub(&malformed, &mint), "the mesh hub refused the inbox read", true),
        (http_hub(&refusing, &mint), "the mesh hub refused the inbox read", false),
        (
            http_hub(&refusing, &["/nonexistent/mesh-token-command"]),
            "this daemon could not ask the mesh hub for the inbox",
            true,
        ),
        (http_hub("http://127.0.0.1:9", &mint), "the mesh hub did not answer", true),
    ];
    for (mesh, words, retryable) in cases {
        let e = team_page(&mesh, true, None).await.unwrap_err();
        assert!(e.message.starts_with(words), "{words}: {e:?}");
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "mesh.unavailable", "{words}");
        assert_eq!(data["retryable"], retryable, "{words}");
    }
}

/// Review of #49453 (follow-up 5): `acpmux inbox read ID` (`mux/team/read`) marks the message
/// read within one bound, not three tries of the HTTP client's 30 s and their backoff. Past it the
/// read is retryable and worded as a read through the hub that was not answered.
#[tokio::test(start_paused = true)]
async fn a_team_read_the_hub_never_answers_ends_within_its_bound() {
    let (hub, fake) = setup(true);
    fake.stalled_reads.store(true, std::sync::atomic::Ordering::SeqCst);
    let mut caller = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let started = tokio::time::Instant::now();
    let read = caller
        .call_within(method::MUX_TEAM_READ, json!({"id": OWN_MESSAGE}), Duration::from_secs(600))
        .await;
    let waited = started.elapsed();
    assert!(waited <= crate::server::mesh_relay::read::READ_WAIT, "waited {waited:?}: {read}");
    assert_eq!(read["error"]["data"]["reason"], "mesh.read_unanswered", "{read}");
    assert_eq!(read["error"]["data"]["retryable"], true, "{read}");
    assert!(read["error"]["message"].as_str().unwrap().contains("did not answer"), "{read}");
}

#[tokio::test]
async fn listen_passes_open_ls_close_and_read_through_to_the_hub() {
    let (hub, fake) = setup(true);
    let mut caller = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    let opened = caller
        .call(
            method::MUX_TEAM_LISTEN,
            json!({"op": "open", "to": "sam/coordinator", "ttlSeconds": 3600}),
        )
        .await;
    assert_eq!(opened["result"]["id"], LISTEN, "{opened}");
    let listed = caller.call(method::MUX_TEAM_LISTEN, json!({"op": "ls"})).await;
    assert_eq!(listed["result"], serde_json::to_value(listens()).unwrap(), "{listed}");
    let closed = caller.call(method::MUX_TEAM_LISTEN, json!({"op": "close", "id": LISTEN})).await;
    assert_eq!(closed["result"], json!({"listening": [], "listeners": []}), "{closed}");
    assert_eq!(
        *fake.listen_calls.lock().unwrap(),
        vec![
            "open @sam/coordinator Some(3600)".to_owned(),
            "ls".to_owned(),
            format!("close {LISTEN}")
        ]
    );
    // Another member's messages, passed on whole: not scoped to this session's own address.
    let read = caller
        .call(method::MUX_TEAM_LISTEN, json!({"op": "read", "to": "@sam/coordinator", "before": 7}))
        .await;
    assert_eq!(read["result"]["messages"].as_array().map(Vec::len), Some(2), "{read}");
    assert_eq!(
        *fake.browsed.lock().unwrap(),
        vec![(false, Some("@sam/coordinator".to_owned()), Some(7))]
    );
}

#[tokio::test]
async fn listen_refuses_remote_callers_bad_addresses_and_bad_ids_before_the_hub() {
    let (hub, fake) = setup(true);
    for (origin, caller) in [(Origin::Peer, None), (Origin::Local, Some((OWN, false)))] {
        let mut denied = Rpc::connect(&hub, origin, caller).await;
        for op in ["open", "ls", "close", "read"] {
            let reply = denied
                .call(
                    method::MUX_TEAM_LISTEN,
                    json!({"op": op, "to": "@sam/coordinator", "id": LISTEN}),
                )
                .await;
            assert!(reply.get("error").is_some(), "{op}: {reply}");
        }
    }
    let mut caller = Rpc::connect(&hub, Origin::Local, Some((OWN, true))).await;
    for params in [
        json!({"op": "open", "to": "nobody"}),
        json!({"op": "open", "to": "@sam/co ordinator"}),
        json!({"op": "read"}),
        json!({"op": "close", "id": "lsn_../../messages"}),
        json!({"op": "close", "id": "lsn_0123456789ABCDEF0123456789ABCDEF"}),
        json!({"op": "close"}),
        json!({"op": "watch"}),
    ] {
        let reply = caller.call(method::MUX_TEAM_LISTEN, params.clone()).await;
        assert_eq!(reply["error"]["code"], -32602, "{params}: {reply}");
    }
    assert!(fake.listen_calls.lock().unwrap().is_empty());
    assert!(fake.browsed.lock().unwrap().is_empty());
}

#[path = "team_directory_tests.rs"]
mod directory;
