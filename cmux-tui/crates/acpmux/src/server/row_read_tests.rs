//! A peer chat's reads that its mirrored row answers (`ROW_WILL_DO`): `acpmux send` reads the
//! chat's state and subscribes to it before its prompt, and on a ready link this daemon answers
//! both from the row its link keeps current, with no round trip to the peer. A link that is not
//! ready leaves the row as old as the link's last notice: the peer is asked, as before.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const CHAT: &str = "0190f2a4-7c1e-7d3a-9f00-00000000c4a7";

/// A hub with peer `far` listing one running chat, its link down.
fn hub_with_peer() -> (Arc<Hub>, Arc<crate::peer::Peer>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let peer = hub.seed_down_peer("far", vec![row()]);
    (hub, peer)
}

/// The chat's row as `far` lists it.
fn row() -> Value {
    json!({"sessionId": CHAT, "name": "lane", "status": "running", "turnCount": 3,
           "queued": 1, "steering": true, "updatedAt": 5})
}

/// `m` with `params` on a new unix-socket connection to `hub`: its result, or its error.
async fn call(hub: &Arc<Hub>, m: &str, params: Value) -> Result<Value, Value> {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    for line in [Message::request(1, method::INITIALIZE, hello), Message::request(2, m, params)] {
        input.send(line.to_line()).await.unwrap();
    }
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), outgoing.recv()).await;
        let reply: Value = serde_json::from_str(&line.unwrap().unwrap()).unwrap();
        if reply.get("id") == Some(&json!(2)) {
            return match reply.get("error") {
                Some(e) => Err(e.clone()),
                None => Ok(reply["result"].clone()),
            };
        }
    }
}

/// On a ready link, a send's read of the chat's state is the row, and nothing goes to the peer.
#[tokio::test]
async fn a_sends_info_of_a_peer_chat_is_answered_from_its_row() {
    let (hub, peer) = hub_with_peer();
    // Ready, with no transport: any request for the peer would fail as unreachable.
    hub.seed_peer_back(&peer, vec![row()]);
    let info =
        call(&hub, method::MUX_INFO, json!({"sessionId": format!("far/{CHAT}"), "row": true}))
            .await
            .expect("answered here");
    assert_eq!(info["row"], true, "{info}");
    assert_eq!(info["status"], "running");
    assert_eq!(info["queued"], 1);
    assert_eq!(info["steering"], true);
    assert_eq!(info["peer"], "far");
    assert_eq!(peer.pending_requests().await, 0);
}

/// A subscription to a chat the link already streams is answered here too; the first one is
/// not (its answer is the chat's replay baseline), nor is an attach that reads records.
#[tokio::test]
async fn a_subscription_to_a_streamed_peer_chat_is_answered_here() {
    let (hub, peer) = hub_with_peer();
    hub.seed_peer_back(&peer, vec![row()]);
    let key = format!("far/{CHAT}");
    let first =
        call(&hub, method::MUX_ATTACH, json!({"sessionId": key, "limit": 0, "row": true})).await;
    assert!(first.is_err(), "the first attach goes to the peer: {first:?}");
    peer.mark_attached(CHAT);
    peer.note_attach_queued(CHAT, &json!({"sessionId": CHAT, "limit": 0}), peer.link_epoch());
    let sub = call(&hub, method::MUX_ATTACH, json!({"sessionId": key, "limit": 0, "row": true}))
        .await
        .expect("answered here");
    assert_eq!(sub["row"], true, "{sub}");
    assert_eq!(sub["events"], json!([]));
    assert_eq!(sub["session"]["status"], "running");
    let page =
        call(&hub, method::MUX_ATTACH, json!({"sessionId": key, "limit": 20, "row": true})).await;
    assert!(page.is_err(), "an attach that reads records goes to the peer: {page:?}");
}

/// A link that is not ready (down, or still handshaking) asks the peer: the row may be old.
#[tokio::test]
async fn a_link_that_is_not_ready_never_answers_from_its_row() {
    let (hub, _peer) = hub_with_peer();
    let info =
        call(&hub, method::MUX_INFO, json!({"sessionId": format!("far/{CHAT}"), "row": true}))
            .await;
    let error = info.expect_err("the peer is asked, and it is down");
    assert_eq!(error["data"]["reason"], "peer_unreachable", "{error}");
}

/// Without the flag, a read of a peer chat goes to the peer, as before.
#[tokio::test]
async fn a_read_without_the_flag_goes_to_the_peer() {
    let (hub, peer) = hub_with_peer();
    hub.seed_peer_back(&peer, vec![row()]);
    let info = call(&hub, method::MUX_INFO, json!({"sessionId": format!("far/{CHAT}")})).await;
    assert!(info.is_err(), "{info:?}");
}

/// A chat another client here attached with a `kinds` filter streams only those kinds over the
/// link: a send's subscription goes to the peer to widen it, and once an attach with no filter
/// reached the link, the next one is answered here again. This link has no transport, so what
/// reached it is noted as the queue would (`Peer::note_attach_queued`).
#[tokio::test]
async fn a_subscription_after_a_filtered_attach_goes_to_the_peer() {
    let (hub, peer) = hub_with_peer();
    hub.seed_peer_back(&peer, vec![row()]);
    let key = format!("far/{CHAT}");
    peer.mark_attached(CHAT);
    let link = peer.link_epoch();
    peer.note_attach_queued(CHAT, &json!({"sessionId": CHAT, "kinds": ["tool_call"]}), link);
    assert!(!peer.streams_every_kind(CHAT));
    let sub = json!({"sessionId": key, "limit": 0, "row": true});
    let widened = call(&hub, method::MUX_ATTACH, sub.clone()).await;
    assert!(widened.is_err(), "a filtered stream is widened by the peer: {widened:?}");
    peer.note_attach_queued(CHAT, &json!({"sessionId": CHAT, "limit": 0}), link);
    assert!(peer.streams_every_kind(CHAT));
    let again = call(&hub, method::MUX_ATTACH, sub).await.expect("answered here");
    assert_eq!(again["row"], true, "{again}");
}

/// #38305 F1: a first attach that never reached the link (here its link was not open) leaves the
/// chat marked, but the peer streams nothing of it: a send's subscription goes to the peer again,
/// rather than be answered here with no stream behind it.
#[tokio::test]
async fn a_subscription_after_a_first_attach_that_never_reached_the_link_goes_to_the_peer() {
    let (hub, peer) = hub_with_peer();
    hub.seed_peer_back(&peer, vec![row()]);
    let sub = json!({"sessionId": format!("far/{CHAT}"), "limit": 0, "row": true});
    let first = call(&hub, method::MUX_ATTACH, sub.clone()).await;
    assert!(first.is_err(), "the first attach goes to the peer: {first:?}");
    assert!(!peer.mark_attached(CHAT), "the failed attach left the chat marked");
    let again = call(&hub, method::MUX_ATTACH, sub).await;
    assert!(again.is_err(), "answered here with no stream from the peer: {again:?}");
}

/// #38305 F2: a link back (connected) whose session list the hub has not applied yet holds the
/// rows of the link before: a send's reads go to the peer until the list is applied.
#[tokio::test]
async fn a_link_whose_rows_are_not_applied_yet_never_answers_from_its_row() {
    let (hub, peer) = hub_with_peer();
    peer.connected.store(true, std::sync::atomic::Ordering::SeqCst);
    let info =
        call(&hub, method::MUX_INFO, json!({"sessionId": format!("far/{CHAT}"), "row": true}))
            .await;
    assert!(info.is_err(), "answered from a row the link has not listed again: {info:?}");
}
