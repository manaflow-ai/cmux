//! A send never blocks on the link (`wait_for_prompt_link`, `capabilities::PROMPT_LINK_WAIT`): a
//! prompt that asks to wait for its chat's link (`waitForLink`) hears `_acpmux/prompt_held` and is
//! held up to `PROMPT_HELD_WAIT` while the peer is down, and goes once it is back; one that does
//! not ask (an older client) gets the short wait of `prompt_link_wait_tests.rs` and no notice.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const CHAT: &str = "0190f2a4-7c1e-7d3a-9f00-00000000b10c";

/// A hub with peer `far` listing one idle chat, its link down.
fn hub_with_peer() -> (Arc<Hub>, Arc<crate::peer::Peer>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let peer = hub.seed_down_peer("far", vec![row()]);
    (hub, peer)
}

fn row() -> Value {
    json!({"sessionId": CHAT, "name": "lane", "status": "idle", "turnCount": 1, "updatedAt": 5})
}

fn prompt(wait: bool) -> Value {
    let mut mux = json!({"promptId": "p-held-1"});
    if wait {
        mux.set("waitForLink", json!(true));
    }
    json!({
        "sessionId": format!("far/{CHAT}"),
        "prompt": [{"type": "text", "text": "keep going"}],
        "_meta": {"acpmux": mux},
    })
}

/// A unix-socket connection that has sent `session/prompt` with `params` as request 2.
struct Sent {
    _input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
}

async fn send(hub: &Arc<Hub>, params: Value) -> Sent {
    let (input, incoming) = mpsc::channel(8);
    let (out, output) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, out, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    for line in [
        Message::request(1, method::INITIALIZE, hello),
        Message::request(2, method::SESSION_PROMPT, params),
    ] {
        input.send(line.to_line()).await.unwrap();
    }
    Sent { _input: input, output }
}

impl Sent {
    /// The next line that is the prompt's reply or a `prompt_held`, within `within`.
    async fn next(&mut self, within: Duration) -> Option<Value> {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.output.recv()).await.ok()??;
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(2))
                || v.get("method").and_then(Value::as_str) == Some(method::MUX_PROMPT_HELD)
            {
                return Some(v);
            }
        }
    }
}

fn reason(v: &Value) -> Option<&str> {
    v.pointer("/error/data/reason").and_then(Value::as_str)
}

/// The old contract, which an older client still gets: no `waitForLink`, no notice, and the
/// short wait (`PROMPT_LINK_WAIT`) before it is refused as unreachable.
#[tokio::test(start_paused = true)]
async fn a_prompt_that_does_not_ask_to_wait_hears_no_notice_and_gets_the_short_wait() {
    let (hub, _peer) = hub_with_peer();
    let mut sent = send(&hub, prompt(false)).await;
    let first = sent.next(PROMPT_LINK_WAIT + Duration::from_secs(5)).await.expect("an answer");
    assert_eq!(first.get("id"), Some(&json!(2)), "no prompt_held first: {first}");
    assert_eq!(reason(&first), Some("peer_unreachable"), "{first}");
}

/// The new contract: held with a notice, unanswered while the link is down, and sent on once the
/// link is back (it then waits on the peer, which has no transport here).
#[tokio::test(start_paused = true)]
async fn a_prompt_that_asks_to_wait_is_held_until_the_link_is_back() {
    let (hub, peer) = hub_with_peer();
    let mut sent = send(&hub, prompt(true)).await;
    let held = sent.next(Duration::from_secs(20)).await.expect("a notice");
    assert_eq!(held["method"], method::MUX_PROMPT_HELD, "{held}");
    assert_eq!(held["params"]["promptId"], "p-held-1");
    assert_eq!(held["params"]["peer"], "far");
    let past_short_wait = PROMPT_LINK_WAIT + Duration::from_secs(30);
    assert!(sent.next(past_short_wait).await.is_none(), "held past the short wait");
    assert_eq!(peer.pending_requests().await, 0, "nothing went to the peer while down");
    // As a finished handshake leaves it: the link open, the peer back, the Connected notice.
    peer.open_link_for_tests();
    hub.seed_peer_back(&peer, vec![row()]);
    hub.peer_snapshots.seed_restored(&peer);
    let notice = (peer.name.clone(), peer.generation, crate::peer::PeerNotice::Connected);
    let _ = hub.peer_notices.send(notice).await;
    // With no transport the peer's request fails or waits; either way it was tried, not refused
    // as unreachable.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if peer.pending_requests().await > 0
            || peer.queued_for_tests(method::SESSION_PROMPT).await > 0
        {
            break;
        }
        if let Ok(Some(line)) =
            tokio::time::timeout(Duration::from_millis(50), sent.output.recv()).await
        {
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(2)) {
                assert_ne!(reason(&v), Some("peer_unreachable"), "sent on, not refused: {v}");
                break;
            }
        }
        assert!(tokio::time::Instant::now() < deadline, "sent on once the link is back");
    }
}

/// A link that never comes back: refused as unreachable once the hold's bound is spent.
#[tokio::test(start_paused = true)]
async fn a_held_prompt_is_refused_once_its_bound_is_spent() {
    let (hub, _peer) = hub_with_peer();
    let mut sent = send(&hub, prompt(true)).await;
    let held = sent.next(Duration::from_secs(20)).await.expect("a notice");
    assert_eq!(held["method"], method::MUX_PROMPT_HELD, "{held}");
    let reply = sent.next(PROMPT_HELD_WAIT + Duration::from_secs(60)).await.expect("refused");
    assert_eq!(reason(&reply), Some("peer_unreachable"), "{reply}");
}

#[test]
fn only_an_explicit_true_asks_to_wait() {
    assert!(waits_for_peer_link(&prompt(true)));
    assert!(!waits_for_peer_link(&prompt(false)));
    assert!(!waits_for_peer_link(&json!({"_meta": {"acpmux": {"waitForLink": "yes"}}})));
}
