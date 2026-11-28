//! A message the hub leases to a machine a chat moved away from goes on to where the chat went
//! (`server/mesh_relay.rs` `forward_moved`), under a key the hub takes.
//!
//! The hub's idempotency key is `[A-Za-z0-9._:-]{8,128}` (cmux-platform `Mesh.ts`), and it
//! answers 400 to any other. The forward's key was `MESSAGE~moved~HOST/SESSION`, so every forward
//! was refused and the text lost: the super-highway ring of 2026-11-28 22:04Z read 71 bounces
//! "the forward was refused: the hub answered 400". The stand-in hub here refuses as the real
//! one does.
//!
//! - a prompt for a chat that moved to `machine-b` is forwarded there, its text, once;
//! - the forward's key is one the hub takes, and the same on a second lease of the message.

use super::*;
use acpmux::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt,
};
use acpmux::server::mesh_relay::{RefuseControl, deliver};
use futures::future::BoxFuture;

const B_KEY: &str = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";

/// A hub that keeps what it is sent, refusing a key it would not take with its 400.
#[derive(Default)]
struct Hub400 {
    sent: std::sync::Mutex<Vec<OutMessage>>,
}

fn hub_takes(key: &str) -> bool {
    (8..=128).contains(&key.len())
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
}

impl MeshHub for Hub400 {
    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            if !hub_takes(&m.idempotency_key) {
                let mut e = HubError::refused("the hub answered 400");
                e.status = Some(400);
                return Err(e);
            }
            self.sent.lock().unwrap().push(m.clone());
            Ok(serde_json::from_value(json!({
                "messageId": format!("msg_{}", m.idempotency_key.len()),
                "state": "queued", "to": m.to, "attempt": 0,
            }))
            .unwrap())
        })
    }
    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        unreachable!("the test delivers by hand")
    }
    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        unreachable!("the test reads the ack deliver answers")
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        unreachable!("no receipt read")
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        unreachable!("no heartbeat here")
    }
}

#[tokio::test]
async fn a_prompt_for_a_chat_that_moved_is_forwarded_under_a_key_the_hub_takes() {
    let (a, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let begin = c
        .request(
            "_acpmux/transfer_begin",
            json!({"sessionId": id, "interrupt": true, "to": {"hub": B_KEY, "host": "machine-b"}}),
        )
        .await
        .unwrap();
    let to = json!({"host": "machine-b", "via": "hub", "sessionId": id});
    let committed = c
        .request(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begin["transferId"], "to": to,
                   "epoch": begin["epoch"]}),
        )
        .await
        .unwrap();
    assert_eq!(committed["committed"], true, "{committed}");

    let hub = Arc::new(Hub400::default());
    a.mesh.set(hub.clone());
    let message: InMessage = serde_json::from_value(json!({
        "messageId": "msg_57a3bf0325560c5c44251358b3ee6b9c", "kind": "prompt", "mode": "now",
        "to": {"sessionId": id},
        "from": {"host": "machine-c", "user": "user-1"},
        "body": "the ring's send",
    }))
    .unwrap();

    let ack = deliver(&a, &message, &RefuseControl, None).await.expect("an answer");
    let ack = serde_json::to_value(&ack).unwrap();
    assert_eq!(ack["state"], "delivered", "{ack}");
    assert!(ack["detail"].as_str().unwrap_or("").contains("forwarded"), "{ack}");

    // A second lease of the same message (a lost ack) posts under the same key.
    deliver(&a, &message, &RefuseControl, None).await.expect("an answer");
    let sent = hub.sent.lock().unwrap().clone();
    assert_eq!(sent.len(), 2, "both leases reached the hub");
    assert_eq!(sent[0].idempotency_key, sent[1].idempotency_key, "one key per message");
    assert!(hub_takes(&sent[0].idempotency_key), "{}", sent[0].idempotency_key);
    assert_eq!(sent[0].body, "the ring's send");
    assert_eq!(sent[0].to.host.as_deref(), Some("machine-b"));
    assert_eq!(sent[0].to.session_id.as_deref(), Some(id.as_str()));
}
